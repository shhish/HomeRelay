import dnssd
import Foundation
import os

struct Config: Sendable {
    var host: String
    var port: Int
    var tokensFile: URL
    /// nil disables the polling fallback.
    var pollInterval: Duration?
    var logReads: Bool

    static let defaultPort = 18796

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Settings come from the LaunchAgent environment; every one has a default.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Config {
        // Not sandboxed, so this is ~/Library/Application Support/HomeRelay.
        let support = URL.applicationSupportDirectory.appending(path: "HomeRelay", directoryHint: .isDirectory)
        let poll = env["HOMERELAY_POLL_SECONDS"].flatMap(Int.init) ?? 30
        return Config(
            // "::" accepts IPv6 and IPv4 (mapped) clients; Bonjour advertises both.
            host: env["HOMERELAY_HOST"] ?? "::",
            port: env["HOMERELAY_PORT"].flatMap(Int.init) ?? defaultPort,
            tokensFile: env["HOMERELAY_TOKENS_FILE"].map { URL(filePath: $0) } ?? support.appending(path: "tokens.json"),
            pollInterval: poll > 0 ? .seconds(poll) : nil,
            logReads: env["HOMERELAY_LOG_READS"] == "1"
        )
    }
}

/// Writes to the unified log and to stderr, which the LaunchAgent sends to
/// logs/homerelay.log in the repo.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "homerelay", category: "service")
    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .current)

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("\(Date().formatted(stamp)) \(level) \(message)\n".utf8))
    }
}

/// Advertises `_homerelay._tcp` so devices such as the ESP32 can find the
/// service with mDNS instead of a hard-coded address.
final class BonjourAdvertiser {
    private var ref: DNSServiceRef?

    init(port: Int, txt: [String: String]) {
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        for (key, value) in txt {
            TXTRecordSetValue(&record, key, UInt8(value.utf8.count), value)
        }
        let status = DNSServiceRegister(
            &ref, 0, 0, "HomeRelay", "_homerelay._tcp", nil, nil,
            UInt16(port).bigEndian, TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record), nil, nil
        )
        TXTRecordDeallocate(&record)
        if status == kDNSServiceErr_NoError {
            Log.info("Advertising _homerelay._tcp on port \(port)")
        } else {
            Log.error("Bonjour registration failed: \(status)")
        }
    }

    deinit {
        if let ref { DNSServiceRefDeallocate(ref) }
    }
}
