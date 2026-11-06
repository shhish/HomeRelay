// AppleTCPServer.swift
// Copyright 2026 Monagle Pty Ltd

#if canImport(Network)
import Foundation
import Network
import Logging
import HAPCore
import HAPCrypto
import HAPTransport

// MARK: - AppleTCPServer

public final class AppleTCPServer: HAPServer, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "hap.apple.tcp")
    private var listener: NWListener?
    private var isStarting = false
    private var connections: [Int: NWConnection] = [:]
    private var contexts: [Int: HAPConnection] = [:]
    private var nextConnectionID = 0
    private let logger: Logger

    // Stored for creating per-connection contexts
    private let bridge: HAPBridge
    private let setupCode: String
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private let loopbackOnly: Bool
    // Set after init by AppleHAPService.start() — must be configured before
    // any connection can trigger a pairing change.
    private var pairingChangeHandler: (@Sendable () async -> Void)?
    var onPairingChange: (@Sendable () async -> Void)? {
        get { lock.withLock { pairingChangeHandler } }
        set { lock.withLock { pairingChangeHandler = newValue } }
    }

    private var _port: UInt16 = 0

    public var port: UInt16 {
        lock.withLock { _port }
    }

    public init(
        bridge: HAPBridge,
        setupCode: String,
        identity: HAPIdentity,
        pairingStore: any PairingStore,
        deviceID: String,
        loopbackOnly: Bool = false,
        logger: Logger = Logger(label: "hap.apple.tcp")
    ) {
        self.bridge = bridge
        self.setupCode = setupCode
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
        self.loopbackOnly = loopbackOnly
        self.logger = logger
    }

    // MARK: - HAPServer

    public func start(port: UInt16) async throws {
        let canStart = lock.withLock {
            guard listener == nil, !isStarting else { return false }
            isStarting = true
            return true
        }
        guard canStart else { throw HAPError.invalidState }
        defer { lock.withLock { isStarting = false } }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!) }
        let listener: NWListener
        if loopbackOnly || port == 0 {
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        lock.withLock { self.listener = listener }

        // Set the state handler BEFORE start() to eliminate the race where .ready
        // fires between start() and a second handler assignment.
        // The continuation is wrapped in a one-shot box because multiple states
        // (.ready then .cancelled) can fire over the listener's lifetime — only
        // the first resume is valid.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // One-shot wrapper: the first resume() consumes the continuation;
                // subsequent calls are no-ops.  Safe without a lock because
                // stateUpdateHandler is always called on the listener's serial queue.
                class ContinuationBox: @unchecked Sendable {
                    var continuation: CheckedContinuation<Void, Error>?
                    init(_ continuation: CheckedContinuation<Void, Error>) {
                        self.continuation = continuation
                    }
                    func resume() {
                        continuation?.resume()
                        continuation = nil
                    }
                    func resume(throwing error: Error) {
                        continuation?.resume(throwing: error)
                        continuation = nil
                    }
                }
                let box = ContinuationBox(continuation)

                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener else { return }
                    switch state {
                    case .ready:
                        if let actualPort = listener.port?.rawValue {
                            self.lock.withLock { self._port = actualPort }
                            self.logger.info("HAP server listening on port \(actualPort)")
                        }
                        box.resume()
                    case .failed(let error):
                        self.logger.error("HAP listener failed: \(error)")
                        box.resume(throwing: error)
                    case .cancelled:
                        self.logger.debug("HAP listener cancelled")
                        box.resume(throwing: HAPError.unavailable)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            lock.withLock {
                if self.listener === listener { self.listener = nil; self._port = 0 }
            }
            listener.cancel()
            throw error
        }

        guard lock.withLock({ self.listener === listener }) else { throw HAPError.unavailable }
    }

    public func stop() async {
        let (currentListener, currentConnections) = lock.withLock {
            let l = self.listener
            let c = self.connections
            self.listener = nil
            self._port = 0
            self.connections.removeAll()
            self.contexts.removeAll()
            return (l, c)
        }

        for (id, connection) in currentConnections {
            connection.cancel()
            await bridge.unsubscribeAll(connectionID: id)
        }
        if let currentListener {
            currentListener.newConnectionHandler = nil
            // cancel() is asynchronous. Wait for .cancelled before allowing a
            // caller to rebind the fixed port in this process.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let previousHandler = currentListener.stateUpdateHandler
                currentListener.stateUpdateHandler = { state in
                    previousHandler?(state)
                    if case .cancelled = state { continuation.resume() }
                }
                currentListener.cancel()
            }
        }
        logger.info("HAP server stopped")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionID = lock.withLock {
            let id = nextConnectionID
            nextConnectionID += 1
            connections[id] = connection
            contexts[id] = HAPConnection(
                bridge: bridge,
                setupCode: setupCode,
                identity: identity,
                pairingStore: pairingStore,
                deviceID: deviceID,
                connectionID: id,
                onPairingChange: self.pairingChangeHandler,
                logger: logger,
                send: { data in
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        })
                    }
                },
                close: { connection.cancel() }
            )
            return id
        }

        logger.debug("New HAP connection \(connectionID)")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.debug("Connection \(connectionID) ready")
                self.receiveData(connection: connection, connectionID: connectionID)
            case .failed(let error):
                self.logger.debug("Connection \(connectionID) failed: \(error)")
                self.removeConnection(connectionID)
            case .cancelled:
                self.logger.debug("Connection \(connectionID) cancelled")
                self.removeConnection(connectionID)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveData(connection: NWConnection, connectionID: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            // Issue the next receive only after processing this one. Concurrent Tasks
            // created for successive callbacks can otherwise reorder the TCP byte stream.
            Task {
                if let data = content, !data.isEmpty,
                   let context = self.lock.withLock({ self.contexts[connectionID] }) {
                    await context.receive(data)
                    await self.revalidateConnections()
                }
                if isComplete || error != nil { self.removeConnection(connectionID) }
                else { self.receiveData(connection: connection, connectionID: connectionID) }
            }
        }
    }

    private func revalidateConnections() async {
        let contexts = lock.withLock { Array(self.contexts.values) }
        for context in contexts { await context.revokeIfUnauthorized() }
    }

    private func removeConnection(_ connectionID: Int) {
        let connection = lock.withLock {
            contexts.removeValue(forKey: connectionID)
            return connections.removeValue(forKey: connectionID)
        }
        connection?.cancel()

        // Clean up event subscriptions for this connection
        Task {
            await bridge.unsubscribeAll(connectionID: connectionID)
        }
    }

    // MARK: - Event Notifications

    /// Send a pre-built EVENT/1.0 payload to a specific connection, encrypted
    /// with that connection's session keys.
    func sendEvent(_ eventData: Data, to connectionID: Int) async {
        guard let context = lock.withLock({ contexts[connectionID] }) else { return }
        await context.sendEvent(eventData)
    }
}
#endif
