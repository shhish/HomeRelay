import Foundation

/// What the HTTP API needs from a home. The app implements this with HomeKit;
/// tests implement it with an in-memory fake.
///
/// `ref` parameters accept an id or a name. Names match case-insensitively,
/// and `Room/Name` narrows a name that exists in more than one room.
public protocol HomeBackend: Sendable {
    func status() async -> BackendStatus
    func homes() async throws -> [HomeSummary]
    func snapshot(home: String?, refresh: Bool) async throws -> [HomeDTO]
    func rooms(home: String?) async throws -> [RoomDTO]
    func accessories(home: String?, room: String?, category: String?, refresh: Bool) async throws -> [AccessoryDTO]
    func accessory(_ ref: String, home: String?, refresh: Bool) async throws -> AccessoryDTO
    /// Writes friendly-named values (`{"on": true, "brightness": 40}`) and returns the accessory afterwards.
    func setAccessory(_ ref: String, home: String?, values: [String: JSONValue]) async throws -> AccessoryDTO
    func toggleAccessory(_ ref: String, home: String?) async throws -> AccessoryDTO
    func writeCharacteristic(id: String, value: JSONValue) async throws -> CharacteristicDTO
    func scenes(home: String?) async throws -> [SceneDTO]
    func runScene(_ ref: String, home: String?) async throws -> SceneDTO
}

/// An error with an HTTP status and a stable machine-readable code.
public struct APIError: Error, Sendable, Equatable {
    public var status: Int
    public var code: String
    public var message: String
    public var candidates: [String]?

    public init(status: Int, code: String, message: String, candidates: [String]? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.candidates = candidates
    }

    public static func badRequest(_ message: String) -> APIError {
        APIError(status: 400, code: "bad_request", message: message)
    }
    public static func notFound(_ message: String) -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }
    public static func ambiguous(_ message: String, candidates: [String]) -> APIError {
        APIError(status: 409, code: "ambiguous", message: message, candidates: candidates)
    }
    public static func unprocessable(_ message: String) -> APIError {
        APIError(status: 422, code: "invalid_value", message: message)
    }
    public static func unavailable(_ message: String) -> APIError {
        APIError(status: 503, code: "homekit_unavailable", message: message)
    }
    public static func deviceFailed(_ message: String) -> APIError {
        APIError(status: 502, code: "device_error", message: message)
    }
    public static func timedOut(_ message: String) -> APIError {
        APIError(status: 504, code: "timeout", message: message)
    }
}

/// Something a client can refer to by id or by name.
public struct Named: Sendable, Equatable {
    public var id: String
    public var name: String
    public var room: String?

    public init(id: String, name: String, room: String? = nil) {
        self.id = id
        self.name = name
        self.room = room
    }

    /// `Room/Name (id)`: the id is the only reliable way to pick between twins
    /// that also share a room.
    var label: String { (room.map { "\($0)/\(name)" } ?? name) + " (\(id))" }
}

public enum RefResolver {
    /// Picks one item for `ref`: an exact id, then a unique name, then `Room/Name`.
    public static func resolve(_ ref: String, in items: [Named], kind: String) throws(APIError) -> Named {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        if let byId = items.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return byId
        }
        let byName = items.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw .ambiguous(
                "\(byName.count) \(kind)s are named '\(trimmed)'; use one of the ids below, or Room/Name if the rooms differ",
                candidates: byName.map(\.label)
            )
        }
        if let slash = trimmed.firstIndex(of: "/") {
            let room = trimmed[..<slash]
            let name = trimmed[trimmed.index(after: slash)...]
            let matches = items.filter {
                $0.name.caseInsensitiveCompare(String(name)) == .orderedSame
                    && ($0.room ?? "").caseInsensitiveCompare(String(room)) == .orderedSame
            }
            if matches.count == 1 { return matches[0] }
        }
        throw .notFound("No \(kind) matches '\(trimmed)'")
    }
}
