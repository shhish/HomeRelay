import CryptoKit
import Foundation
import Synchronization

/// What a token is allowed to do.
public enum TokenScope: String, Codable, Sendable {
    /// Read state, list things and subscribe to events.
    case read
    /// Everything `read` can do, plus writes and scenes.
    case control
}

public struct TokenRecord: Codable, Sendable, Equatable {
    public var name: String
    public var scope: TokenScope
    /// Hex SHA-256 of the token. The token itself is never stored.
    public var sha256: String
    public var created: String?

    public init(name: String, scope: TokenScope, sha256: String, created: String? = nil) {
        self.name = name
        self.scope = scope
        self.sha256 = sha256
        self.created = created
    }
}

/// Bearer tokens kept as hashes in a JSON file that `scripts/homerelay-token`
/// manages. The file is re-read when it changes, so adding or revoking a
/// token needs no restart.
public final class TokenStore: Sendable {
    private struct FileShape: Codable {
        var tokens: [TokenRecord]
    }

    private struct State {
        var records: [TokenRecord] = []
        var modified: Date?
    }

    public let path: URL
    private let state = Mutex(State())

    public init(path: URL) {
        self.path = path
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The record for a presented token, or nil if it is unknown.
    public func verify(_ token: String) -> TokenRecord? {
        guard !token.isEmpty else { return nil }
        let presented = Array(Self.hash(token).utf8)
        return currentRecords().first { constantTimeEquals(Array($0.sha256.lowercased().utf8), presented) }
    }

    public var count: Int { currentRecords().count }

    private func currentRecords() -> [TokenRecord] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        return state.withLock { state in
            if modified != state.modified {
                state.modified = modified
                if let data = try? Data(contentsOf: path), let file = try? JSONDecoder().decode(FileShape.self, from: data) {
                    state.records = file.tokens
                } else {
                    state.records = []
                }
            }
            return state.records
        }
    }

    private func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
