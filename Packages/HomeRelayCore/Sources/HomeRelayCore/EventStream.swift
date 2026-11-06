import Foundation

/// Serves one `/events` connection as a pull-based byte stream: the HTTP writer
/// asks for the next chunk only when the previous one is on the wire, so a
/// replay of thousands of events never outruns a slow client.
///
/// With an event log, the stream is gap-free: it replays from `since` first,
/// skips live events it already sent, and when it notices it missed live events
/// (its buffer overflowed) it catches up from the log before going on. Anything
/// the log no longer has is announced with a `gap` frame.
actor EventStreamSession {
    private enum Item: Sendable {
        case live(HubItem)
        case tick
    }

    private let log: EventLog?
    private let accessoryIds: Set<String>?
    private let since: Int64?
    /// The store id the client's `since` came from, if it said.
    private let store: String?
    /// Last `seq` this client has been given (or deliberately skipped past).
    private var cursor: Int64?
    private var replaying = false
    private var started = false
    private var items: AsyncStream<Item>.Iterator
    private let tasks: [Task<Void, Never>]
    private static let batch = 200

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init(hub: EventHub, since: Int64?, store: String?, accessoryIds: Set<String>?, heartbeat: Duration) {
        log = hub.log
        self.accessoryIds = accessoryIds
        self.since = hub.log == nil ? nil : since
        self.store = store
        let (merged, sink) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(512))
        // Subscribe before replaying, so nothing published meanwhile is missed.
        let subscription = hub.subscribe()
        tasks = [
            Task {
                for await item in subscription { sink.yield(.live(item)) }
                sink.finish()
            },
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: heartbeat)
                    if Task.isCancelled { break }
                    sink.yield(.tick)
                }
            },
        ]
        items = merged.makeAsyncIterator()
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    /// The next chunk to write, or nil to end the response.
    func next() async -> Data? {
        if !started {
            started = true
            var out = Data(": homerelay events\nretry: 3000\n\n".utf8)
            if let since, let log { out += await beginReplay(after: since, log) }
            return out
        }
        while true {
            if replaying, let log {
                let out = await replayBatch(log)
                if !out.isEmpty { return out }
            }
            var iterator = items
            let item = await iterator.next(isolation: self)
            items = iterator
            switch item {
            case nil:
                return nil
            case .tick:
                return Data(": keepalive\n\n".utf8)
            case .live(let hubItem):
                let out = live(hubItem)
                if !out.isEmpty { return out }
            }
        }
    }

    // MARK: - Replay

    private func beginReplay(after since: Int64, _ log: EventLog) async -> Data {
        let latest = log.latestSeq
        if since > latest || (store != nil && store != log.storeId) {
            // The client's position is from another (or a reset) log.
            cursor = latest
            return gap(from: since + 1, to: nil, reason: "reset")
        }
        cursor = since
        replaying = true
        let oldest = await log.oldestSeq()
        if let oldest, since + 1 < oldest {
            cursor = oldest - 1
            return gap(from: since + 1, to: oldest - 1, reason: "expired")
        }
        if oldest == nil, since < latest {
            cursor = latest
            replaying = false
            return gap(from: since + 1, to: latest, reason: "expired")
        }
        return Data()
    }

    /// The next visible events from the log; stops replaying once caught up.
    private func replayBatch(_ log: EventLog) async -> Data {
        while true {
            let events = await log.events(after: cursor ?? 0, limit: Self.batch)
            if events.isEmpty {
                replaying = false
                return Data()
            }
            var out = Data()
            for event in events {
                guard let seq = event.seq else { continue }
                if let c = cursor, seq > c + 1 {
                    out += gap(from: c + 1, to: seq - 1, reason: "lost")
                }
                cursor = seq
                out += frame(event)
            }
            // A batch of nothing but samples just advances the cursor.
            if !out.isEmpty { return out }
        }
    }

    // MARK: - Live

    private func live(_ item: HubItem) -> Data {
        guard log != nil, let seq = item.event.seq else { return frame(item.event) }
        guard let c = cursor else {
            cursor = seq
            return frame(item.event)
        }
        if seq <= c { return Data() }
        if let previous = item.previous, previous > c {
            // Missed live events: catch up from the log, which has this one too.
            replaying = true
            return Data()
        }
        cursor = seq
        return frame(item.event)
    }

    // MARK: - Frames

    private func visible(_ event: HomeEvent) -> Bool {
        if event.origin == "sample" { return false }
        if let ids = accessoryIds, !ids.contains(event.accessoryId ?? "") { return false }
        return true
    }

    private func frame(_ event: HomeEvent) -> Data {
        guard visible(event), let payload = try? Self.encoder.encode(event) else { return Data() }
        var head = ""
        if let seq = event.seq { head += "id: \(seq)\n" }
        head += "event: \(event.type)\ndata: "
        return Data(head.utf8) + payload + Data("\n\n".utf8)
    }

    private func gap(from: Int64, to: Int64?, reason: String) -> Data {
        struct Gap: Encodable {
            var type = "gap"
            var missingFrom: Int64
            var missingTo: Int64?
            var reason: String
            var store: String?
            var ts = HomeEvent.now()
        }
        let payload = (try? Self.encoder.encode(Gap(missingFrom: from, missingTo: to, reason: reason, store: log?.storeId))) ?? Data()
        // The id moves the client's Last-Event-ID past the hole.
        let id = cursor.map { "id: \($0)\n" } ?? ""
        return Data("\(id)event: gap\ndata: ".utf8) + payload + Data("\n\n".utf8)
    }
}
