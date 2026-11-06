// CharacteristicProtocol.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import CoreFoundation
import HAPCore
import HAPCrypto
import Logging

// MARK: - CharacteristicProtocol

public actor CharacteristicProtocol {
    private var preparedWrite: (pid: UInt64, deadline: ContinuousClock.Instant)?
    private let bridge: HAPBridge
    private let pairingStateMachine: PairingStateMachine
    private let pairVerifyStateMachine: PairVerifyStateMachine
    private let pairingStore: any PairingStore
    private let identity: HAPIdentity
    private let onPairingChange: (@Sendable () async -> Void)?
    let connectionID: Int
    private let logger = Logger(label: "hap.characteristic")

    public init(
        bridge: HAPBridge,
        pairingStateMachine: PairingStateMachine,
        pairVerifyStateMachine: PairVerifyStateMachine,
        pairingStore: any PairingStore,
        identity: HAPIdentity,
        connectionID: Int = 0,
        onPairingChange: (@Sendable () async -> Void)? = nil
    ) {
        self.bridge = bridge
        self.pairingStateMachine = pairingStateMachine
        self.pairVerifyStateMachine = pairVerifyStateMachine
        self.pairingStore = pairingStore
        self.identity = identity
        self.connectionID = connectionID
        self.onPairingChange = onPairingChange
    }

    public func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        logger.debug("\(request.method) \(request.path) (\(request.body.count) bytes)")
        if request.method == "POST", request.path == "/identify" {
            guard !(await pairingStore.isPaired) else {
                return HTTPProtocol.errorResponse(status: 400, message: "Already Paired")
            }
            return HTTPProtocol.noContentResponse()
        }
        let pairingEndpoint = request.method == "POST" && ["/pair-setup", "/pair-verify"].contains(request.path)
        let authorized = try await pairVerifyStateMachine.isAuthorized()
        if !pairingEndpoint && !authorized {
            return HTTPProtocol.errorResponse(status: 470, message: "Connection Authorization Required")
        }
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            return try await handlePairSetup(request)
        case ("POST", "/pair-verify"):
            return try await handlePairVerify(request)
        case ("POST", "/pairings"):
            return try await handlePairings(request)
        case ("GET", "/accessories"):
            return try await handleGetAccessories()
        case ("GET", let path) where path.hasPrefix("/characteristics"):
            return try await handleGetCharacteristics(request)
        case ("PUT", "/characteristics"):
            return try await handlePutCharacteristics(request)
        case ("PUT", "/prepare"):
            return try handlePrepare(request)
        default:
            logger.warning("Unhandled request: \(request.method) \(request.path)")
            return HTTPProtocol.errorResponse(status: 404, message: "Not Found")
        }
    }

    // MARK: - Pair Setup

    private func handlePairSetup(_ request: HTTPRequest) async throws -> HTTPResponse {
        let responseData = try await pairingStateMachine.handleRequest(request.body)
        let items = try TLV8.decode(responseData)
        if items.contains(where: { $0.type == TLV8Type.state.rawValue && $0.value == Data([6]) }),
           !items.contains(where: { $0.type == TLV8Type.error.rawValue }) { await onPairingChange?() }
        return HTTPProtocol.okResponse(body: responseData, contentType: HTTPProtocol.pairingTLV8)
    }

    // MARK: - Pair Verify

    private func handlePairVerify(_ request: HTTPRequest) async throws -> HTTPResponse {
        let responseData = try await pairVerifyStateMachine.handleRequest(request.body)
        return HTTPProtocol.okResponse(body: responseData, contentType: HTTPProtocol.pairingTLV8)
    }

    // MARK: - POST /pairings (Add / Remove / List)

    private func handlePairings(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let controller = await pairVerifyStateMachine.controllerIdentifier,
              try await pairingStore.permission(for: controller) == .admin else {
            return pairingsErrorResponse(error: .authentication)
        }
        let items = try TLV8.decode(request.body)
        guard items.contains(where: { $0.type == TLV8Type.state.rawValue && $0.value == Data([1]) }) else {
            return pairingsErrorResponse(error: .unknown)
        }
        guard let methodData = items.first(where: { $0.type == TLV8Type.method.rawValue })?.value,
              let method = methodData.first else {
            logger.warning("POST /pairings: missing method TLV")
            return pairingsErrorResponse(error: .unknown)
        }

        switch method {
        case 3: return try await handleAddPairing(items)
        case 4: return try await handleRemovePairing(items)
        case 5: return try await handleListPairings()
        default:
            logger.warning("POST /pairings: unknown method \(method)")
            return pairingsErrorResponse(error: .unknown)
        }
    }

    private func handleAddPairing(_ items: [TLV8.Item]) async throws -> HTTPResponse {
        guard let identifierData = items.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let identifier = String(data: identifierData, encoding: .utf8),
              let publicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value else {
            logger.warning("POST /pairings Add: missing identifier or public key")
            return pairingsErrorResponse(error: .unknown)
        }

        guard !identifier.isEmpty, publicKey.count == 32,
              let permissions = items.first(where: { $0.type == TLV8Type.permissions.rawValue })?.value,
              permissions.count == 1, let permission = PairingPermission(rawValue: permissions[0]) else {
            return pairingsErrorResponse(error: .unknown)
        }
        if let existing = try await pairingStore.publicKey(for: identifier), existing != publicKey {
            return pairingsErrorResponse(error: .unknown)
        }
        try await pairingStore.store(controllerIdentifier: identifier, publicKey: publicKey, permission: permission)
        await onPairingChange?()

        return HTTPProtocol.okResponse(
            body: TLV8.encode([(type: TLV8Type.state.rawValue, value: Data([2]))]),
            contentType: HTTPProtocol.pairingTLV8
        )
    }

    private func handleRemovePairing(_ items: [TLV8.Item]) async throws -> HTTPResponse {
        guard let identifierData = items.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let identifier = String(data: identifierData, encoding: .utf8) else {
            logger.warning("POST /pairings Remove: missing identifier")
            return pairingsErrorResponse(error: .unknown)
        }

        logger.info("POST /pairings: Remove pairing for '\(identifier)'")
        try await pairingStore.remove(controllerIdentifier: identifier)

        let stillPaired = await pairingStore.isPaired
        logger.debug("POST /pairings: pairing removed. Still paired: \(stillPaired)")
        await onPairingChange?()

        return HTTPProtocol.okResponse(
            body: TLV8.encode([(type: TLV8Type.state.rawValue, value: Data([2]))]),
            contentType: HTTPProtocol.pairingTLV8
        )
    }

    private func handleListPairings() async throws -> HTTPResponse {
        let pairings = try await pairingStore.listPairings()
        logger.debug("POST /pairings: List (\(pairings.count) pairing(s))")

        var tlvItems: [TLV8.Item] = [
            (type: TLV8Type.state.rawValue, value: Data([2])),
        ]
        for (index, pairing) in pairings.enumerated() {
            if index > 0 {
                tlvItems.append((type: TLV8Type.separator.rawValue, value: Data()))
            }
            tlvItems.append((type: TLV8Type.identifier.rawValue, value: Data(pairing.identifier.utf8)))
            tlvItems.append((type: TLV8Type.publicKey.rawValue, value: pairing.publicKey))
            tlvItems.append((type: TLV8Type.permissions.rawValue, value: Data([pairing.permission.rawValue])))
        }

        return HTTPProtocol.okResponse(
            body: TLV8.encode(tlvItems),
            contentType: HTTPProtocol.pairingTLV8
        )
    }

    private func pairingsErrorResponse(error: TLV8ErrorCode) -> HTTPResponse {
        let tlv = TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([2])),
            (type: TLV8Type.error.rawValue, value: Data([error.rawValue])),
        ])
        return HTTPProtocol.okResponse(body: tlv, contentType: HTTPProtocol.pairingTLV8)
    }

    // MARK: - PUT /prepare (Timed Writes)

    /// A prepare belongs to this verified connection and is consumed by the next write.
    /// ContinuousClock is monotonic, so wall-clock corrections cannot extend a TTL.
    private func handlePrepare(_ request: HTTPRequest) throws -> HTTPResponse {
        preparedWrite = nil
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let pid = unsignedInteger(json["pid"]), let ttl = unsignedInteger(json["ttl"]),
              ttl > 0, ttl <= UInt64(UInt32.max) else {
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }
        preparedWrite = (pid, ContinuousClock.now.advanced(by: .milliseconds(Int64(ttl))))
        return HTTPProtocol.okResponse(body: try JSONSerialization.data(withJSONObject: ["status": 0]),
                                       contentType: HTTPProtocol.hapJSON)
    }

    private func unsignedInteger(_ raw: Any?) -> UInt64? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue >= 0, n.doubleValue.rounded() == n.doubleValue else { return nil }
        return UInt64(n.stringValue)
    }

    // MARK: - GET /accessories

    func handleGetAccessories() async throws -> HTTPResponse {
        let accessories = await bridge.accessoryDatabase()
        let json = encodeAccessoryDatabase(accessories)
        if let str = String(data: json, encoding: .utf8) {
            logger.debug("GET /accessories (\(accessories.count) accessories)")
            logger.trace("GET /accessories body:\n\(str)")
        }
        return HTTPProtocol.okResponse(body: json, contentType: HTTPProtocol.hapJSON)
    }

    // MARK: - GET /characteristics?id=AID.IID,...

    private func handleGetCharacteristics(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let queryStart = request.path.firstIndex(of: "?") else {
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }

        let query = request.path[request.path.index(after: queryStart)...]
        guard query.hasPrefix("id=") else {
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }

        let idsString = query.dropFirst(3).split(separator: "&").first ?? ""
        let ids = idsString.split(separator: ",")
        var characteristics: [[String: Any]] = []
        var hasError = false
        for id in ids {
            let parts = id.split(separator: ".")
            guard parts.count == 2, let aid = UInt64(parts[0]), let iid = UInt64(parts[1]) else {
                return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
            }
            var result: [String: Any] = ["aid": aid, "iid": iid]
            if let char = await bridge.characteristic(aid: aid, iid: iid) {
                if !char.isReadable { result["status"] = HAPStatus.writeOnly.rawValue; hasError = true }
                else if let value = char.value { result["value"] = encodeValue(value) }
            } else { result["status"] = HAPStatus.resourceDoesNotExist.rawValue; hasError = true }
            characteristics.append(result)
        }
        if hasError {
            for index in characteristics.indices where characteristics[index]["status"] == nil {
                characteristics[index]["status"] = 0
            }
        }
        return HTTPResponse(statusCode: hasError ? 207 : 200, statusMessage: hasError ? "Multi-Status" : "OK",
                            headers: [("Content-Type", HTTPProtocol.hapJSON)],
                            body: try JSONSerialization.data(withJSONObject: ["characteristics": characteristics]))
    }

    // MARK: - PUT /characteristics

    private func handlePutCharacteristics(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let characteristics = parsed["characteristics"] as? [[String: Any]] else {
            logger.warning("PUT /characteristics: failed to parse JSON body (\(request.body.count) bytes)")
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }

        let prepared = preparedWrite
        preparedWrite = nil
        let pid = unsignedInteger(parsed["pid"])
        let timedStatus: HAPStatus = {
            guard let pid, let prepared, pid == prepared.pid else { return .invalidValueInRequest }
            return ContinuousClock.now <= prepared.deadline ? .success : .operationTimedOut
        }()
        var results: [[String: Any]] = []
        for entry in characteristics {
            guard let aid = unsignedInteger(entry["aid"]), let iid = unsignedInteger(entry["iid"]) else {
                return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
            }
            var status = HAPStatus.success
            if let char = await bridge.characteristic(aid: aid, iid: iid) {
                if entry["value"] != nil && (parsed["pid"] != nil || char.permissions.contains(.timedWrite)) && timedStatus != .success {
                    status = timedStatus
                } else if entry["value"] != nil && !char.isWritable { status = .readOnly }
                else if entry["ev"] != nil && !char.supportsNotification { status = .notificationNotSupported }
                else {
                    if let raw = entry["value"] {
                        if let value = decodeValue(raw, for: char) {
                            do { try await bridge.writeCharacteristic(aid: aid, iid: iid, value: value, sourceConnectionID: connectionID) }
                            catch { status = .communicationFailure }
                        } else { status = .invalidValueInRequest }
                    }
                    if status == .success, let ev = entry["ev"] {
                        if let number = ev as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                            if number.boolValue { await bridge.subscribe(connectionID: connectionID, aid: aid, iid: iid) }
                            else { await bridge.unsubscribe(connectionID: connectionID, aid: aid, iid: iid) }
                        } else { status = .invalidValueInRequest }
                    }
                }
            } else { status = .resourceDoesNotExist }
            results.append(["aid": aid, "iid": iid, "status": status.rawValue])
        }
        guard results.contains(where: { ($0["status"] as? Int) != 0 }) else { return HTTPProtocol.noContentResponse() }
        return HTTPResponse(statusCode: 207, statusMessage: "Multi-Status", headers: [("Content-Type", HTTPProtocol.hapJSON)],
                            body: try JSONSerialization.data(withJSONObject: ["characteristics": results]))
    }

    // MARK: - JSON Encoding

    private func encodeAccessoryDatabase(_ accessories: [HAPAccessory]) -> Data {
        var accessoryList: [[String: Any]] = []

        for accessory in accessories {
            var serviceList: [[String: Any]] = []

            for service in accessory.services {
                var charList: [[String: Any]] = []

                for char in service.characteristics {
                    var charDict: [String: Any] = [
                        "iid": char.iid,
                        "type": char.type.rawValue,
                        "perms": char.permissions.map(\.rawValue),
                        "format": char.format.rawValue,
                    ]
                    if let value = char.value {
                        charDict["value"] = encodeValue(value)
                    }
                    if let v = char.minValue { charDict["minValue"] = v }
                    if let v = char.maxValue { charDict["maxValue"] = v }
                    if let v = char.minStep { charDict["minStep"] = v }
                    if let v = char.unit { charDict["unit"] = v.rawValue }
                    if let v = char.validValues { charDict["valid-values"] = v }
                    charList.append(charDict)
                }

                serviceList.append([
                    "iid": service.iid,
                    "type": service.type.rawValue,
                    "characteristics": charList,
                ])
            }

            accessoryList.append([
                "aid": accessory.aid,
                "services": serviceList,
            ])
        }

        let json: [String: Any] = ["accessories": accessoryList]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private func encodeValue(_ value: HAPCharacteristicValue) -> Any {
        switch value {
        case .bool(let v): return v
        case .uint8(let v): return v
        case .uint16(let v): return v
        case .uint32(let v): return v
        case .int32(let v): return v
        case .float(let v): return v
        case .string(let v): return v
        case .data(let v): return v.base64EncodedString()
        case .tlv8(let v): return v.base64EncodedString()
        }
    }

    private func decodeValue(_ raw: Any, for char: HAPCharacteristic) -> HAPCharacteristicValue? {
        if char.format == .string, let string = raw as? String { return .string(string) }
        if char.format == .data || char.format == .tlv8, let string = raw as? String,
           let data = Data(base64Encoded: string) { return char.format == .data ? .data(data) : .tlv8(data) }
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, char.minValue.map({ value >= $0 }) ?? true,
              char.maxValue.map({ value <= $0 }) ?? true else { return nil }
        if let valid = char.validValues, !valid.contains(where: { Double($0) == value }) { return nil }
        switch char.format {
        case .bool:
            guard value == 0 || value == 1 else { return nil }
            return .bool(number.boolValue)
        case .float: return .float(value)
        case .uint8:
            guard value >= 0, value <= Double(UInt8.max), value.rounded() == value else { return nil }
            return .uint8(number.uint8Value)
        case .uint16:
            guard value >= 0, value <= Double(UInt16.max), value.rounded() == value else { return nil }
            return .uint16(number.uint16Value)
        case .uint32:
            guard value >= 0, value <= Double(UInt32.max), value.rounded() == value else { return nil }
            return .uint32(number.uint32Value)
        case .int:
            guard value >= Double(Int32.min), value <= Double(Int32.max), value.rounded() == value else { return nil }
            return .int32(number.int32Value)
        default: return nil
        }
    }
}
