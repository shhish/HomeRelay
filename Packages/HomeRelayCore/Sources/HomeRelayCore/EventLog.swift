import Foundation
import Synchronization

/// The durable event log (the "hot tier"): every event HomeRelay publishes,
/// numbered with a `seq` that keeps increasing across restarts, kept in SQLite
/// on the internal disk. Clients resume `/events` from it, and the history
/// archiver copies from it.
///
/// `append` is synchronous and cheap: it numbers the event and queues it. A
/// timer writes the queue in one transaction per second, so a crash loses at
/// most about a second of events. All SQLite work happens on one serial queue.
public final class EventLog: @unchecked Sendable {
    public struct Settings: Sendable {
        /// Archived rows older than this are deleted.
        public var retention: Duration = .seconds(14 * 86_400)
        /// Past this, the oldest rows are deleted even if not yet archived, and
        /// the loss is counted in `dropped`.
        public var maxBytes: Int64 = 2 * 1_073_741_824
        public var flushEvery: Duration = .seconds(1)
        public var maintainEvery: Duration = .seconds(3_600)
        /// How often the session's last-alive time is saved, which bounds how
        /// precisely a crash's gap is known.
        public var heartbeatEvery: Duration = .seconds(30)
        public init() {}
    }

    public struct Stats: Codable, Sendable, Equatable {
        public var store: String
        public var latestSeq: Int64
        public var oldestSeq: Int64?
        public var oldestTs: String?
        public var rows: Int64
        public var bytes: Int64
        public var pending: Int
        public var dropped: Int64
        public var lastError: String?
        public var windowHours: Int
        /// Events in the window by `type`, and characteristic events by `origin`.
        public var byType: [String: Int64]
        public var byOrigin: [String: Int64]
        public var sessions: Int64
    }

    private struct Pending {
        var seq: Int64
        var tsMs: Int64
        var event: HomeEvent
    }

    private struct State {
        var nextSeq: Int64
        var pending: [Pending] = []
        var dropped: Int64 = 0
        var lastError: String?
        var closed = false
    }

    public let storeId: String
    public let path: URL
    private let settings: Settings
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "homerelay.eventlog")
    /// Only touched on `queue`.
    private let db: SQLiteDB
    private let sessionId: Int64
    private let state: Mutex<State>
    private var timers: [DispatchSourceTimer] = []
    private var lastHeartbeat = Date.distantPast
    /// Upper bound on queued events if the disk keeps failing; past it the
    /// oldest are dropped rather than growing memory without limit.
    private static let maxPending = 100_000
    /// Far more events than arrive between two flushes.
    static let uncleanSkip: Int64 = 10_000
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(
        path: URL, settings: Settings = Settings(), clock: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.path = path
        self.settings = settings
        self.clock = clock
        self.log = log
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS events (
                seq INTEGER PRIMARY KEY,
                ts_ms INTEGER NOT NULL,
                type TEXT NOT NULL,
                origin TEXT,
                accessory_id TEXT,
                characteristic_id TEXT,
                json TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS events_ts ON events(ts_ms);
            CREATE INDEX IF NOT EXISTS events_unarchived ON events(seq) WHERE archived = 0;
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY,
                started_ms INTEGER NOT NULL,
                alive_ms INTEGER NOT NULL,
                stopped_ms INTEGER,
                reason TEXT,
                first_seq INTEGER
            );
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        let now = Self.ms(clock())
        let (store, next, session) = try db.transaction { () throws -> (String, Int64, Int64) in
            var store = try Self.meta(db, "store_id")
            if store == nil {
                store = UUID().uuidString
                try db.run("INSERT INTO meta(key, value) VALUES ('store_id', ?), ('schema', '1')", [.text(store!)])
            }
            // `last_seq` survives retention deleting every row, so numbers are never reused.
            let fromMeta = try Self.meta(db, "last_seq").flatMap { Int64($0) } ?? 0
            let fromRows = try db.scalar("SELECT MAX(seq) FROM events") ?? 0
            var next = max(fromMeta, fromRows) + 1
            // A session still open means the last run ended without saying so.
            // Numbers it handed out in its last second were streamed but never
            // written; skip past them so no client holds a seq that now means
            // a different event. Replays show the skipped range as `lost`.
            try db.run("UPDATE sessions SET stopped_ms = alive_ms, reason = 'unclean' WHERE stopped_ms IS NULL")
            if db.changes > 0 { next += Self.uncleanSkip }
            try db.run("INSERT INTO sessions(started_ms, alive_ms, first_seq) VALUES (?, ?, ?)", [.int(now), .int(now), .int(next)])
            return (store!, next, try db.scalar("SELECT last_insert_rowid()") ?? 0)
        }
        self.db = db
        self.storeId = store
        self.sessionId = session
        self.state = Mutex(State(nextSeq: next))
        self.lastHeartbeat = clock()
    }

    /// Starts the flush and maintenance timers.
    public func start() {
        queue.async { [self] in
            guard timers.isEmpty else { return }
            timers = [
                timer(every: settings.flushEvery) { $0.flushOnQueue() },
                timer(every: settings.maintainEvery) { $0.maintainOnQueue() },
            ]
        }
    }

    /// Writes what's queued and marks this session as stopped.
    public func close(reason: String = "stopped") {
        queue.sync {
            timers.forEach { $0.cancel() }
            timers = []
            flushOnQueue()
            try? db.run("UPDATE sessions SET alive_ms = ?, stopped_ms = ?, reason = ? WHERE id = ?",
                        [.int(Self.ms(clock())), .int(Self.ms(clock())), .text(reason), .int(sessionId)])
            state.withLock { $0.closed = true }
        }
    }

    // MARK: - Writing

    /// Numbers `event`, queues it for the next write and returns it with `seq` set.
    func append(_ event: HomeEvent) -> HomeEvent {
        let now = Self.ms(clock())
        return state.withLock { s in
            var numbered = event
            numbered.seq = s.nextSeq
            s.nextSeq += 1
            s.pending.append(Pending(seq: numbered.seq!, tsMs: now, event: numbered))
            if s.pending.count > Self.maxPending {
                let excess = s.pending.count - Self.maxPending
                s.pending.removeFirst(excess)
                s.dropped += Int64(excess)
            }
            return numbered
        }
    }

    /// Writes queued events now. The timer does this every second.
    public func flush() {
        queue.sync { flushOnQueue() }
    }

    private func flushOnQueue() {
        let batch = state.withLock { s -> [Pending] in
            defer { s.pending = [] }
            return s.pending
        }
        let now = clock()
        let heartbeat = now.timeIntervalSince(lastHeartbeat) >= Double(settings.heartbeatEvery.components.seconds)
        guard !batch.isEmpty || heartbeat else { return }
        do {
            try db.transaction {
                if !batch.isEmpty {
                    let insert = try db.prepare(
                        "INSERT OR IGNORE INTO events(seq, ts_ms, type, origin, accessory_id, characteristic_id, json) VALUES (?, ?, ?, ?, ?, ?, ?)"
                    )
                    for p in batch {
                        let json = String(decoding: try Self.encoder.encode(p.event), as: UTF8.self)
                        try insert.bind([
                            .int(p.seq), .int(p.tsMs), .text(p.event.type), .optional(p.event.origin),
                            .optional(p.event.accessoryId), .optional(p.event.characteristicId), .text(json),
                        ])
                        while try insert.step() {}
                    }
                    try db.run("INSERT INTO meta(key, value) VALUES ('last_seq', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               [.text(String(batch.last!.seq))])
                }
                try db.run("UPDATE sessions SET alive_ms = ? WHERE id = ?", [.int(Self.ms(now)), .int(sessionId)])
            }
            lastHeartbeat = now
            state.withLock { $0.lastError = nil }
        } catch {
            // Put the batch back in front of anything queued since; the next tick retries.
            state.withLock { s in
                s.pending = batch + s.pending
                if s.lastError == nil { log("Event log write failed: \(error)") }
                s.lastError = "\(error)"
            }
        }
    }

    // MARK: - Reading

    /// Events with `seq` greater than `after`, oldest first, from disk and the
    /// write queue. Includes `sample` events; callers filter.
    public func events(after: Int64, limit: Int = 500) async -> [HomeEvent] {
        await onQueue { [self] in
            var out: [HomeEvent] = []
            var last = after
            if let stmt = try? db.prepare("SELECT json FROM events WHERE seq > ? ORDER BY seq LIMIT ?") {
                try? stmt.bind([.int(after), .int(Int64(limit))])
                let decoder = JSONDecoder()
                while (try? stmt.step()) == true {
                    if let text = stmt.text(0), let e = try? decoder.decode(HomeEvent.self, from: Data(text.utf8)) {
                        out.append(e)
                        last = e.seq ?? last
                    }
                }
            }
            // Flushes also run on this queue, so nothing is between disk and queue.
            if out.count < limit {
                let queued = state.withLock { $0.pending }
                out += queued.lazy.filter { $0.seq > last }.prefix(limit - out.count).map(\.event)
            }
            return out
        }
    }

    /// The newest `seq` handed out, or 0 before the first event.
    public var latestSeq: Int64 {
        state.withLock { $0.nextSeq - 1 }
    }

    /// The oldest `seq` still available, or nil when the log is empty.
    public func oldestSeq() async -> Int64? {
        await onQueue { [self] in
            if let fromDisk = try? db.scalar("SELECT MIN(seq) FROM events") { return fromDisk }
            return state.withLock { $0.pending.first?.seq }
        }
    }

    /// `ok`, or `failing` while writes are erroring.
    public var health: String {
        state.withLock { $0.lastError == nil ? "ok" : "failing" }
    }

    public func stats(windowHours: Int = 24) async -> Stats {
        await onQueue { [self] in
            let queued = state.withLock { $0.pending.count }
            flushOnQueue()
            let since = Self.ms(clock()) - Int64(windowHours) * 3_600_000
            func counts(_ column: String, _ filter: String) -> [String: Int64] {
                var out: [String: Int64] = [:]
                guard let stmt = try? db.prepare("SELECT \(column), COUNT(*) FROM events WHERE ts_ms >= ? \(filter) GROUP BY 1") else { return out }
                try? stmt.bind([.int(since)])
                while (try? stmt.step()) == true { out[stmt.text(0) ?? "none"] = stmt.int(1) }
                return out
            }
            let oldest = try? db.scalar("SELECT MIN(seq) FROM events")
            let oldestTs = try? db.scalar("SELECT MIN(ts_ms) FROM events")
            let s = state.withLock { $0 }
            return Stats(
                store: storeId,
                latestSeq: s.nextSeq - 1,
                oldestSeq: oldest,
                oldestTs: oldestTs.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted(.iso8601) },
                rows: (try? db.scalar("SELECT COUNT(*) FROM events")) ?? 0,
                bytes: usedBytes(),
                pending: queued,
                dropped: s.dropped + ((try? Self.meta(db, "dropped")).flatMap { Int64($0) } ?? 0),
                lastError: s.lastError,
                windowHours: windowHours,
                byType: counts("type", ""),
                byOrigin: counts("origin", "AND type = 'characteristic'"),
                sessions: (try? db.scalar("SELECT COUNT(*) FROM sessions WHERE alive_ms >= ?", [.int(since)])) ?? 0
            )
        }
    }

    // MARK: - Maintenance

    /// Applies retention now. The timer does this hourly.
    public func maintain() {
        queue.sync { maintainOnQueue() }
    }

    private func maintainOnQueue() {
        flushOnQueue()
        let cutoff = Self.ms(clock()) - Int64(settings.retention.components.seconds) * 1000
        do {
            try db.run("DELETE FROM events WHERE archived = 1 AND ts_ms < ?", [.int(cutoff)])
            let expired = db.changes
            // Over the cap: drop the oldest tenth, archived or not, and count it.
            var lost = 0
            while usedBytes() > settings.maxBytes, let total = try db.scalar("SELECT COUNT(*) FROM events"), total > 0 {
                let n = max(Int64(1), total / 10)
                try db.run("DELETE FROM events WHERE seq IN (SELECT seq FROM events ORDER BY seq LIMIT ?)", [.int(n)])
                lost += db.changes
            }
            if lost > 0 {
                let previous = try Self.meta(db, "dropped").flatMap { Int64($0) } ?? 0
                try db.run("INSERT INTO meta(key, value) VALUES ('dropped', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(String(previous + Int64(lost)))])
                log("Event log over \(settings.maxBytes / 1_048_576) MB: dropped the \(lost) oldest events")
            }
            try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            let hour = Self.ms(clock()) - 3_600_000
            let lastHour = try db.scalar("SELECT COUNT(*) FROM events WHERE ts_ms >= ?", [.int(hour)]) ?? 0
            log("Event log: \(lastHour) events in the last hour, \(usedBytes() / 1024) KB on disk, \(expired) expired")
        } catch {
            log("Event log maintenance failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func usedBytes() -> Int64 {
        let pages = (try? db.scalar("PRAGMA page_count")) ?? 0
        let free = (try? db.scalar("PRAGMA freelist_count")) ?? 0
        let size = (try? db.scalar("PRAGMA page_size")) ?? 4096
        return (pages - free) * size
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func timer(every interval: Duration, _ body: @escaping @Sendable (EventLog) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ms = Int(interval / .milliseconds(1))
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(max(10, ms / 10)))
        t.setEventHandler { [weak self] in if let self { body(self) } }
        t.resume()
        return t
    }

    private static func meta(_ db: SQLiteDB, _ key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?")
        try stmt.bind([.text(key)])
        return try stmt.step() ? stmt.text(0) : nil
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
