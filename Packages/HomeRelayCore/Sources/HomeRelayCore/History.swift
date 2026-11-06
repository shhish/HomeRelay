import Foundation
import Synchronization

/// HomeKit metadata for a characteristic, used to pick how its history is summarised.
public struct SeriesMeta: Sendable {
    public var type: String
    public var format: String?
    public var unit: String?
    public var validValues: [Int]?
    public var min: Double?
    public var max: Double?

    public init(type: String, format: String?, unit: String?, validValues: [Int]?, min: Double?, max: Double?) {
        self.type = type
        self.format = format
        self.unit = unit
        self.validValues = validValues
        self.min = min
        self.max = max
    }
}

/// Looks up metadata for characteristic ids; the app answers from HomeKit.
public typealias SeriesMetaProvider = @Sendable ([String]) async -> [String: SeriesMeta]

/// Long-term history (the "cold tier"): copies the event log to SQLite files
/// in a directory on another disk, keeps 5-minute, hourly and daily rollups,
/// applies retention, backs up to the internal disk, and answers history queries.
///
/// The directory is used only while it holds `.homerelay-store` with this
/// install's store id, so an unmounted disk never gets files written to the
/// mount point underneath it. Nothing here blocks HomeKit or the event log: a
/// slow disk only delays archiving, and the event log keeps everything not yet
/// copied. Recent-window summaries come from the event log, so they work even
/// while the disk is away.
public final class History: @unchecked Sendable {
    public struct Settings: Sendable {
        public var archiveEvery: Duration = .seconds(60)
        /// Small batches keep each disk job short, so queries interleave.
        public var batch = 500
        /// Refuse a directory on the boot volume (the app sets this; tests can't).
        public var requireSeparateVolume = false
        public var rawMonths = 24
        public var fiveMinuteDays = 5 * 366
        public var backupsKept = 7
        /// Local hour after which the daily retention and backup run.
        public var maintenanceHour = 3
        /// How long the disk may be missing before health says so.
        public var missingGrace: Duration = .seconds(3_600)
        public var maxLag: Duration = .seconds(86_400)
        public init() {}
    }

    public enum ColdState: String, Codable, Sendable {
        case ok, missing, foreign, failing, off
    }

    public struct Status: Codable, Sendable, Equatable {
        public var cold: ColdState
        public var healthy: Bool
        public var archivedThrough: String?
        public var lagS: Int?
        public var lastRun: String?
        public var lastRunMs: Int?
        public var lastError: String?
        public var unavailableSince: String?
        public var droppedAt: String?
    }

    public struct SeriesInfo: Codable, Sendable, Equatable {
        public var id: Int64
        public var characteristicId: String
        public var accessoryId: String?
        public var serviceId: String?
        public var type: String
        public var kind: SeriesKind
        public var unit: String?
        public var home: String?
        public var room: String?
        public var accessory: String?
        public var firstSeen: String
        public var lastSeen: String
    }

    public struct RawPoint: Codable, Sendable, Equatable {
        public var t: Int64
        public var value: Double?
        public var text: String?
        public var origin: String?
    }

    public struct SeriesHistory: Codable, Sendable, Equatable {
        public var series: SeriesInfo
        /// Present for `step=raw`.
        public var points: [RawPoint]?
        /// Present for rollup steps, one per bucket from `from` to `to`.
        public var buckets: [RollupRow]?
        public var truncated: Bool?
    }

    public struct Response: Codable, Sendable, Equatable {
        public var from: Int64
        public var to: Int64
        public var step: String
        /// Times HomeRelay wasn't running, as `[start, end]` ms pairs.
        public var gaps: [[Int64]]
        public var series: [SeriesHistory]
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var characteristicId: String
        public var type: String?
        public var kind: SeriesKind
        public var from: Int64
        public var to: Int64
        public var current: Double?
        public var currentText: String?
        public var since: Int64?
        public var summary: RollupRow
    }

    private struct SeriesRecord {
        var id: Int64
        var characteristicId: String
        var accessoryId: String?
        var serviceId: String?
        var type: String
        var kind: SeriesKind
        var unit: String?
        var firstSeen: Int64
        var lastSeen: Int64
        var names: (home: String?, room: String?, accessory: String?)
    }

    private struct DirtyKey: Hashable {
        var series: Int64
        var step: BucketStep
        var bucket: Int64
    }

    private struct State {
        var cold: ColdState
        var archivedThroughMs: Int64?
        var lastRunMs: Int64?
        var lastError: String?
        var unavailableSinceMs: Int64?
    }

    public let dir: URL?
    public let backups: URL?
    public let log: EventLog
    private let meta: SeriesMetaProvider
    private let settings: Settings
    private let clock: @Sendable () -> Date
    private let zone: TimeZone
    private let logger: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "homerelay.history")
    private let state: Mutex<State>

    // Only touched on `queue`.
    private var rollups: SQLiteDB?
    private var months: [String: SQLiteDB] = [:]
    private var catalog: [String: SeriesRecord] = [:]
    private var spans: [UpSpan] = []
    /// Session rows learned this run, written in the same transaction as the
    /// rollups they invalidate, so a failed run re-derives them next time.
    private var pendingSessions: [EventLog.Session] = []
    private var lastMaintenanceDay: String?
    private var loop: Task<Void, Never>?

    public init(
        dir: URL?, backups: URL?, log: EventLog, meta: @escaping SeriesMetaProvider = { _ in [:] },
        settings: Settings = Settings(), zone: TimeZone = .current,
        clock: @escaping @Sendable () -> Date = { Date() }, logger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dir = dir
        self.backups = backups
        self.log = log
        self.meta = meta
        self.settings = settings
        self.zone = zone
        self.clock = clock
        self.logger = logger
        state = Mutex(State(cold: dir == nil ? .off : .missing))
    }

    /// Archives every `archiveEvery` and runs daily maintenance.
    public func start() {
        guard dir != nil, loop == nil else { return }
        loop = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.archive()
                await self.maintainIfDue()
                try? await Task.sleep(for: self.settings.archiveEvery)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: - Status

    public func status() async -> Status {
        let s = state.withLock { $0 }
        let now = Self.ms(clock())
        let oldest = await log.oldestUnarchivedMs()
        let dropped = await log.lastDropMs()
        let lag = (s.cold == .off || oldest == nil) ? nil : Int((now - oldest!) / 1000)
        var healthy = true
        if s.cold != .ok, s.cold != .off, let since = s.unavailableSinceMs,
           now - since > Int64(settings.missingGrace.components.seconds) * 1000 { healthy = false }
        if let lag, lag > Int(settings.maxLag.components.seconds) { healthy = false }
        if let dropped, now - dropped < 86_400_000 { healthy = false }
        return Status(
            cold: s.cold, healthy: healthy,
            archivedThrough: s.archivedThroughMs.map(Self.iso), lagS: lag,
            lastRun: s.lastRunMs.map(Self.iso), lastRunMs: s.lastRunMs.map { Int($0) }, lastError: s.lastError,
            unavailableSince: s.cold == .ok ? nil : s.unavailableSinceMs.map(Self.iso),
            droppedAt: dropped.map(Self.iso)
        )
    }

    // MARK: - Archiving

    /// Copies everything new from the event log, then updates rollups.
    public func archive() async {
        guard dir != nil else { return }
        guard await onQueue({ self.openCold() }) else { return }
        let sessions = await log.sessions()
        var dirty = await onQueue { self.syncSessions(sessions) }
        for _ in 0..<50 {
            let rows = await log.unarchived(limit: settings.batch)
            if rows.isEmpty { break }
            let ids = Set(rows.compactMap { $0.event.type == "characteristic" ? $0.event.characteristicId : nil })
            let unknown = await onQueue { ids.filter { self.catalog[$0] == nil } }
            let metas = unknown.isEmpty ? [:] : await meta(Array(unknown))
            let pending = dirty
            guard let written = await onQueue({ self.write(rows, metas: metas, dirty: pending) }) else { return }
            dirty = []
            await log.markArchived(through: rows.last!.seq)
            state.withLock { $0.archivedThroughMs = written }
            if rows.count < settings.batch { break }
        }
        // Anything left (or session rows not yet written) commits here.
        let pending = dirty
        await onQueue { self.recomputeInTransaction(pending) }
        state.withLock { $0.lastRunMs = Self.ms(self.clock()) }
    }

    /// Opens (or re-checks) the cold directory. False when it can't be used.
    private func openCold() -> Bool {
        guard let dir else { return false }
        let marker = dir.appending(path: ".homerelay-store")
        let content = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content else { return unavailable(.missing, "No \(marker.path); the disk may be unmounted") }
        guard content == log.storeId else {
            return unavailable(.foreign, "\(marker.path) belongs to another HomeRelay install")
        }
        if settings.requireSeparateVolume, Self.device(dir.path) == Self.device("/") {
            return unavailable(.missing, "\(dir.path) is on the boot volume; its disk may be unmounted")
        }
        if rollups != nil { return true }
        do {
            try FileManager.default.createDirectory(at: dir.appending(path: "history/raw"), withIntermediateDirectories: true)
            let db = try SQLiteDB(path: dir.appending(path: "history/rollups.sqlite").path)
            try db.exec("""
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS series (
                    series_id INTEGER PRIMARY KEY, characteristic_id TEXT UNIQUE NOT NULL, accessory_id TEXT,
                    service_id TEXT, type TEXT NOT NULL, kind TEXT NOT NULL, unit TEXT,
                    first_seen_ms INTEGER NOT NULL, last_seen_ms INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS series_names (
                    series_id INTEGER NOT NULL, valid_from_ms INTEGER NOT NULL, home TEXT, room TEXT, accessory TEXT,
                    PRIMARY KEY (series_id, valid_from_ms)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS sessions (
                    id INTEGER PRIMARY KEY, started_ms INTEGER NOT NULL, alive_ms INTEGER NOT NULL, stopped_ms INTEGER, reason TEXT);
                """)
            for step in BucketStep.allCases {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS \(step.table) (
                        series_id INTEGER NOT NULL, bucket_ms INTEGER NOT NULL, n INTEGER NOT NULL, cov_s REAL NOT NULL,
                        min REAL, max REAL, mean REAL, last REAL, last_text TEXT, last_ms INTEGER, on_s REAL,
                        transitions INTEGER NOT NULL, states TEXT, PRIMARY KEY (series_id, bucket_ms)) WITHOUT ROWID;
                    """)
            }
            try db.run("INSERT OR IGNORE INTO meta(key, value) VALUES ('store_id', ?), ('schema', '1'), ('day_zone', ?)",
                       [.text(log.storeId), .text(zone.identifier)])
            rollups = db
            try loadCatalog()
            state.withLock { s in
                if s.cold != .ok { logger("History: using \(dir.path)") }
                s.cold = .ok
                s.lastError = nil
                s.unavailableSinceMs = nil
            }
            return true
        } catch {
            closeCold()
            return unavailable(.failing, "Opening history failed: \(error)")
        }
    }

    private func unavailable(_ cold: ColdState, _ message: String) -> Bool {
        closeCold()
        let now = Self.ms(clock())
        state.withLock { s in
            if s.cold != cold || s.lastError != message { logger("History: \(message)") }
            if s.unavailableSinceMs == nil || s.cold == .ok { s.unavailableSinceMs = now }
            s.cold = cold
            s.lastError = message
        }
        return false
    }

    private func closeCold() {
        rollups = nil
        months = [:]
    }

    /// A write or read on the disk failed: drop connections and retry next run.
    private func failed(_ error: Error) {
        _ = unavailable(.failing, "History I/O failed: \(error)")
    }

    private func loadCatalog() throws {
        guard let db = rollups else { return }
        catalog = [:]
        let stmt = try db.prepare("""
            SELECT s.series_id, s.characteristic_id, s.accessory_id, s.service_id, s.type, s.kind, s.unit, s.first_seen_ms, s.last_seen_ms,
                   n.home, n.room, n.accessory
            FROM series s LEFT JOIN series_names n ON n.series_id = s.series_id
             AND n.valid_from_ms = (SELECT MAX(valid_from_ms) FROM series_names WHERE series_id = s.series_id)
            """)
        while try stmt.step() {
            let record = SeriesRecord(
                id: stmt.int(0), characteristicId: stmt.text(1) ?? "", accessoryId: stmt.text(2), serviceId: stmt.text(3),
                type: stmt.text(4) ?? "", kind: SeriesKind(rawValue: stmt.text(5) ?? "") ?? .numeric, unit: stmt.text(6),
                firstSeen: stmt.int(7), lastSeen: stmt.int(8), names: (stmt.text(9), stmt.text(10), stmt.text(11))
            )
            catalog[record.characteristicId] = record
        }
    }

    /// Notes the hot session table; a session newly known to have ended makes
    /// the buckets it ended in stale for every series it covered. The rows are
    /// written later, with those buckets' recompute.
    private func syncSessions(_ sessions: [EventLog.Session]) -> Set<DirtyKey> {
        spans = UpSpan.from(sessions)
        pendingSessions = sessions
        guard let db = rollups else { return [] }
        var dirty: Set<DirtyKey> = []
        do {
            var openInCold: Set<Int64> = []
            var knownInCold: Set<Int64> = []
            let stmt = try db.prepare("SELECT id, stopped_ms FROM sessions")
            while try stmt.step() {
                knownInCold.insert(stmt.int(0))
                if stmt.isNull(1) { openInCold.insert(stmt.int(0)) }
            }
            for s in sessions {
                // Ended since we last looked (or first seen already ended, after a long absence).
                guard let stopped = s.stoppedMs, openInCold.contains(s.id) || !knownInCold.contains(s.id) else { continue }
                for record in catalog.values where record.lastSeen >= s.startedMs && record.firstSeen <= stopped {
                    for step in BucketStep.allCases {
                        dirty.insert(DirtyKey(series: record.id, step: step, bucket: step.start(of: stopped, in: zone)))
                    }
                }
            }
        } catch {
            failed(error)
        }
        return dirty
    }

    private func writeSessions() throws {
        guard let db = rollups, !pendingSessions.isEmpty else { return }
        let upsert = try db.prepare("""
            INSERT INTO sessions(id, started_ms, alive_ms, stopped_ms, reason) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET alive_ms = excluded.alive_ms, stopped_ms = excluded.stopped_ms, reason = excluded.reason
            """)
        for s in pendingSessions {
            try upsert.bind([.int(s.id), .int(s.startedMs), .int(s.aliveMs), s.stoppedMs.map { .int($0) } ?? .null, .optional(s.reason)])
            while try upsert.step() {}
        }
        pendingSessions = []
    }

    /// Writes rows to their monthly raw files and recomputes the buckets they
    /// touch. Returns the log time of the last row, or nil if the disk failed.
    private func write(_ rows: [EventLog.Row], metas: [String: SeriesMeta], dirty initial: Set<DirtyKey>) -> Int64? {
        guard let db = rollups else { return nil }
        var dirty = initial
        do {
            try db.exec("BEGIN IMMEDIATE")
            var byMonth: [String: [EventLog.Row]] = [:]
            for row in rows { byMonth[Self.month(row.tsMs), default: []].append(row) }
            for (month, monthRows) in byMonth.sorted(by: { $0.key < $1.key }) {
                let file = try monthDB(month, create: true)!
                try file.transaction {
                    let sample = try file.prepare("INSERT OR IGNORE INTO samples(series_id, ts_ms, value, value_text, origin, seq) VALUES (?, ?, ?, ?, ?, ?)")
                    let reach = try file.prepare("INSERT OR IGNORE INTO reachability(accessory_id, ts_ms, reachable, seq) VALUES (?, ?, ?, ?)")
                    for row in monthRows {
                        let e = row.event
                        switch e.type {
                        case "characteristic":
                            guard let cid = e.characteristicId else { continue }
                            let series = try ensureSeries(cid, event: e, at: row.tsMs, meta: metas[cid])
                            let point = HistoryPoint(ts: row.tsMs, json: e.value)
                            try sample.bind([
                                .int(series.id), .int(row.tsMs), .optionalReal(point.value),
                                .optional(point.text), .int(Self.originCode(e.origin)), .int(row.seq),
                            ])
                            while try sample.step() {}
                            for step in BucketStep.allCases {
                                dirty.insert(DirtyKey(series: series.id, step: step, bucket: step.start(of: row.tsMs, in: zone)))
                            }
                        case "reachability":
                            guard let aid = e.accessoryId, let reachable = e.reachable else { continue }
                            try reach.bind([.text(aid), .int(row.tsMs), .int(reachable ? 1 : 0), .int(row.seq)])
                            while try reach.step() {}
                        default:
                            continue
                        }
                    }
                }
            }
            try recompute(dirty)
            let sessions = pendingSessions
            try writeSessions()
            do {
                try db.exec("COMMIT")
            } catch {
                pendingSessions = sessions
                throw error
            }
            return rows.last!.tsMs
        } catch {
            try? db.exec("ROLLBACK")
            // The catalog may hold series whose insert was rolled back.
            try? loadCatalog()
            failed(error)
            return nil
        }
    }

    private func ensureSeries(_ cid: String, event e: HomeEvent, at ts: Int64, meta m: SeriesMeta?) throws -> SeriesRecord {
        guard let db = rollups else { throw SQLiteDB.Failure(description: "history closed") }
        let names = (home: e.home, room: e.room, accessory: e.accessory)
        if var record = catalog[cid] {
            if ts > record.lastSeen {
                record.lastSeen = ts
                try db.run("UPDATE series SET last_seen_ms = ? WHERE series_id = ?", [.int(ts), .int(record.id)])
            }
            if names.home != nil || names.accessory != nil,
               names != record.names {
                try db.run("INSERT OR REPLACE INTO series_names(series_id, valid_from_ms, home, room, accessory) VALUES (?, ?, ?, ?, ?)",
                           [.int(record.id), .int(ts), .optional(names.home), .optional(names.room), .optional(names.accessory)])
                record.names = names
            }
            catalog[cid] = record
            return record
        }
        let type = e.characteristic ?? m?.type ?? "unknown"
        let kind = SeriesKind.infer(type: type, format: m?.format, validValues: m?.validValues, min: m?.min, max: m?.max, sample: e.value)
        try db.run("""
            INSERT INTO series(characteristic_id, accessory_id, service_id, type, kind, unit, first_seen_ms, last_seen_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(cid), .optional(e.accessoryId), .optional(e.serviceId), .text(type), .text(kind.rawValue), .optional(m?.unit), .int(ts), .int(ts)])
        let id = try db.scalar("SELECT last_insert_rowid()") ?? 0
        try db.run("INSERT OR REPLACE INTO series_names(series_id, valid_from_ms, home, room, accessory) VALUES (?, ?, ?, ?, ?)",
                   [.int(id), .int(ts), .optional(names.home), .optional(names.room), .optional(names.accessory)])
        let record = SeriesRecord(id: id, characteristicId: cid, accessoryId: e.accessoryId, serviceId: e.serviceId, type: type,
                                  kind: kind, unit: m?.unit, firstSeen: ts, lastSeen: ts, names: names)
        catalog[cid] = record
        return record
    }

    private func recomputeInTransaction(_ dirty: Set<DirtyKey>) {
        guard let db = rollups, !dirty.isEmpty || !pendingSessions.isEmpty else { return }
        let sessions = pendingSessions
        do {
            try db.transaction {
                try recompute(dirty)
                try writeSessions()
            }
        } catch {
            pendingSessions = sessions
            failed(error)
        }
    }

    private func recompute(_ dirty: Set<DirtyKey>) throws {
        guard let db = rollups else { return }
        let byId = Dictionary(catalog.values.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for key in dirty {
            guard let series = byId[key.series] else { continue }
            let end = key.step.end(of: key.bucket, in: zone)
            let prior = try rawPrior(series.id, before: key.bucket)
            let points = try rawPoints(series.id, from: key.bucket, to: end)
            let row = Rollup.compute(kind: series.kind, start: key.bucket, end: end, prior: prior, points: points.map(\.point), up: spans)
            if row.n == 0 {
                try db.run("DELETE FROM \(key.step.table) WHERE series_id = ? AND bucket_ms = ?", [.int(series.id), .int(key.bucket)])
                continue
            }
            let states = row.states.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            try db.run("""
                INSERT OR REPLACE INTO \(key.step.table)
                (series_id, bucket_ms, n, cov_s, min, max, mean, last, last_text, last_ms, on_s, transitions, states)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .int(series.id), .int(key.bucket), .int(Int64(row.n)), .real(row.coverage), .optionalReal(row.min),
                    .optionalReal(row.max), .optionalReal(row.mean), .optionalReal(row.last), .optional(row.lastText),
                    row.lastMs.map { .int($0) } ?? .null, .optionalReal(row.on), .int(Int64(row.transitions)), .optional(states),
                ])
        }
    }

    // MARK: - Raw files

    private func monthDB(_ month: String, create: Bool) throws -> SQLiteDB? {
        if let open = months[month] { return open }
        guard let dir else { return nil }
        let url = dir.appending(path: "history/raw/\(month).sqlite")
        if !create, !FileManager.default.fileExists(atPath: url.path) { return nil }
        let db = try SQLiteDB(path: url.path)
        try db.exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS samples (
                series_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL, value REAL, value_text TEXT, origin INTEGER NOT NULL,
                seq INTEGER NOT NULL, PRIMARY KEY (series_id, ts_ms, seq)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS reachability (
                accessory_id TEXT NOT NULL, ts_ms INTEGER NOT NULL, reachable INTEGER NOT NULL, seq INTEGER NOT NULL,
                PRIMARY KEY (accessory_id, ts_ms, seq)) WITHOUT ROWID;
            """)
        // Keep the months in use (normally this one and the last) open.
        if months.count >= 4, let oldest = months.keys.sorted().first { months[oldest] = nil }
        months[month] = db
        return db
    }

    private struct RawRow {
        var point: HistoryPoint
        var origin: Int64
    }

    private func rawPoints(_ series: Int64, from: Int64, to: Int64) throws -> [RawRow] {
        var out: [RawRow] = []
        for month in Self.months(from: from, to: to - 1) {
            guard let db = try monthDB(month, create: false) else { continue }
            let stmt = try db.prepare("SELECT ts_ms, value, value_text, origin FROM samples WHERE series_id = ? AND ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms, seq")
            try stmt.bind([.int(series), .int(from), .int(to)])
            while try stmt.step() {
                out.append(RawRow(point: HistoryPoint(ts: stmt.int(0), value: stmt.isNull(1) ? nil : stmt.real(1), text: stmt.text(2)), origin: stmt.int(3)))
            }
        }
        return out
    }

    /// The value in force just before `before`, looking back through older
    /// month files until one has a value for the series.
    private func rawPrior(_ series: Int64, before: Int64) throws -> HistoryPoint? {
        let this = Self.month(before - 1)
        for month in [this] + rawMonths().filter({ $0 < this }).reversed() {
            guard let db = try monthDB(month, create: false) else { continue }
            let stmt = try db.prepare("SELECT ts_ms, value, value_text FROM samples WHERE series_id = ? AND ts_ms < ? ORDER BY ts_ms DESC, seq DESC LIMIT 1")
            try stmt.bind([.int(series), .int(before)])
            if try stmt.step() {
                return HistoryPoint(ts: stmt.int(0), value: stmt.isNull(1) ? nil : stmt.real(1), text: stmt.text(2))
            }
        }
        return nil
    }

    /// Month files on disk, oldest first.
    private func rawMonths() -> [String] {
        guard let dir else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "history/raw").path)) ?? []
        return files.filter { $0.hasSuffix(".sqlite") }.map { String($0.dropLast(7)) }.sorted()
    }

    // MARK: - Queries

    public func series(accessory: String? = nil, type: String? = nil) async throws -> [SeriesInfo] {
        try await onQueueThrowing { [self] in
            guard openCold() else { throw APIError(status: 503, code: "history_unavailable", message: state.withLock { $0.lastError } ?? "History is off") }
            return catalog.values
                .filter { accessory == nil || $0.accessoryId == accessory }
                .filter { type == nil || $0.type == type }
                .sorted { ($0.names.accessory ?? "", $0.type) < ($1.names.accessory ?? "", $1.type) }
                .map(info)
        }
    }

    private func info(_ r: SeriesRecord) -> SeriesInfo {
        SeriesInfo(id: r.id, characteristicId: r.characteristicId, accessoryId: r.accessoryId, serviceId: r.serviceId, type: r.type,
                   kind: r.kind, unit: r.unit, home: r.names.home, room: r.names.room, accessory: r.names.accessory,
                   firstSeen: Self.iso(r.firstSeen), lastSeen: Self.iso(r.lastSeen))
    }

    /// Values for `refs` (series ids or characteristic ids) over `[from, to)`.
    /// `step` is `raw`, `5m`, `1h`, `1d` or `auto` (the finest step that stays
    /// under about 2,000 points per series).
    public func query(_ refs: [String], from: Int64, to: Int64, step requested: String) async throws -> Response {
        guard to > from else { throw APIError.badRequest("to must be after from") }
        guard refs.count <= 20 else { throw APIError.badRequest("At most 20 series per request") }
        // Values not yet archived come from the event log.
        let archived = state.withLock { $0.archivedThroughMs } ?? Int64.min
        let response: Response = try await onQueueThrowing { [self] in
            guard openCold() else { throw APIError(status: 503, code: "history_unavailable", message: state.withLock { $0.lastError } ?? "History is off") }
            let byId = Dictionary(catalog.values.map { (String($0.id), $0) }, uniquingKeysWith: { a, _ in a })
            let records = try refs.map { ref -> SeriesRecord in
                guard let r = catalog[ref] ?? byId[ref] else { throw APIError.notFound("No history for series \(ref)") }
                return r
            }
            let step = try chooseStep(requested, from: from, to: to, records: records)
            var out = Response(from: from, to: to, step: step?.rawValue ?? "raw", gaps: gaps(from: from, to: to), series: [])
            for r in records {
                if let step {
                    out.series.append(SeriesHistory(series: info(r), buckets: try buckets(r, step: step, from: from, to: to)))
                } else {
                    let rows = try rawPoints(r.id, from: from, to: to)
                    let limit = 10_000
                    out.series.append(SeriesHistory(
                        series: info(r),
                        points: rows.prefix(limit).map { RawPoint(t: $0.point.ts, value: $0.point.value, text: $0.point.text, origin: Self.originName($0.origin)) },
                        truncated: rows.count > limit ? true : nil
                    ))
                }
            }
            return out
        }
        guard response.step == "raw", to > archived else { return response }
        var merged = response
        for i in merged.series.indices {
            let cid = merged.series[i].series.characteristicId
            let tail = await log.characteristicRows(cid, fromMs: max(from, archived + 1), toMs: to).rows
            let points = tail.map { row -> RawPoint in
                let p = HistoryPoint(ts: row.tsMs, json: row.event.value)
                return RawPoint(t: p.ts, value: p.value, text: p.text, origin: row.event.origin)
            }
            // The archive cursor can move between the two reads; drop exact repeats.
            let known = Set((merged.series[i].points ?? []).map { "\($0.t)|\($0.origin ?? "")|\($0.value.map { String($0) } ?? $0.text ?? "")" })
            var combined = (merged.series[i].points ?? []) + points.filter {
                !known.contains("\($0.t)|\($0.origin ?? "")|\($0.value.map { String($0) } ?? $0.text ?? "")")
            }
            if combined.count > 10_000 {
                combined = Array(combined.prefix(10_000))
                merged.series[i].truncated = true
            }
            merged.series[i].points = combined
        }
        return merged
    }

    private func chooseStep(_ requested: String, from: Int64, to: Int64, records: [SeriesRecord]) throws -> BucketStep? {
        switch requested {
        case "raw": return nil
        case "auto", "":
            let span = to - from
            if span <= 6 * 3_600_000 {
                let counts = try records.map { try rawCount($0.id, from: from, to: to) }
                if counts.allSatisfy({ $0 <= 2_000 }) { return nil }
            }
            return BucketStep.allCases.first { span / $0.nominalMs <= 2_000 } ?? .day
        default:
            guard let step = BucketStep(rawValue: requested) else { throw APIError.badRequest("step must be raw, 5m, 1h, 1d or auto") }
            if span(from, to) / step.nominalMs > 5_000 { throw APIError.badRequest("Too many \(requested) buckets; use a coarser step") }
            return step
        }
    }

    private func span(_ from: Int64, _ to: Int64) -> Int64 { to - from }

    private func rawCount(_ series: Int64, from: Int64, to: Int64) throws -> Int64 {
        var total: Int64 = 0
        for month in Self.months(from: from, to: to - 1) {
            guard let db = try monthDB(month, create: false) else { continue }
            total += try db.scalar("SELECT COUNT(*) FROM samples WHERE series_id = ? AND ts_ms >= ? AND ts_ms < ?", [.int(series), .int(from), .int(to)]) ?? 0
        }
        return total
    }

    /// Stored buckets, with the empty ones in between filled by holding the
    /// previous value (within HomeRelay's running time).
    private func buckets(_ r: SeriesRecord, step: BucketStep, from: Int64, to: Int64) throws -> [RollupRow] {
        guard let db = rollups else { return [] }
        let first = step.start(of: from, in: zone)
        var stored: [Int64: RollupRow] = [:]
        let stmt = try db.prepare("""
            SELECT bucket_ms, n, cov_s, min, max, mean, last, last_text, last_ms, on_s, transitions, states
            FROM \(step.table) WHERE series_id = ? AND bucket_ms >= ? AND bucket_ms < ? ORDER BY bucket_ms
            """)
        try stmt.bind([.int(r.id), .int(first), .int(to)])
        while try stmt.step() {
            let row = Self.rollupRow(stmt)
            stored[row.bucket] = row
        }
        var prior: HistoryPoint?
        let before = try db.prepare("SELECT last, last_text, last_ms FROM \(step.table) WHERE series_id = ? AND bucket_ms < ? ORDER BY bucket_ms DESC LIMIT 1")
        try before.bind([.int(r.id), .int(first)])
        if try before.step(), !before.isNull(2) {
            prior = HistoryPoint(ts: before.int(2), value: before.isNull(0) ? nil : before.real(0), text: before.text(1))
        }
        var out: [RollupRow] = []
        var bucket = first
        let now = Self.ms(clock())
        while bucket < to {
            let end = step.end(of: bucket, in: zone)
            if end > now, bucket <= now {
                // The bucket in progress: stored rows hold the value to its end, so count only time so far.
                let points = try rawPoints(r.id, from: bucket, to: now + 1).map(\.point)
                let start = try rawPrior(r.id, before: bucket) ?? prior
                out.append(Rollup.compute(kind: r.kind, start: bucket, end: now, prior: start, points: points, up: spans))
            } else if let row = stored[bucket] {
                out.append(row)
                if let ms = row.lastMs { prior = HistoryPoint(ts: ms, value: row.last, text: row.lastText) }
            } else {
                out.append(Rollup.compute(kind: r.kind, start: bucket, end: end, prior: prior, points: [], up: spans))
            }
            bucket = end
        }
        return out
    }

    private func gaps(from: Int64, to: Int64) -> [[Int64]] {
        var out: [[Int64]] = []
        var cursor = from
        for span in spans where span.end > from && span.start < to {
            if span.start > cursor { out.append([cursor, span.start]) }
            cursor = max(cursor, span.end)
        }
        if cursor < to, cursor != .max { out.append([cursor, to]) }
        return out
    }

    /// A summary of one characteristic over the last `window`, from the event
    /// log (so it works while the history disk is away). For routine conditions
    /// such as "average temperature over the last hour".
    public func summary(_ ref: String, window: Duration) async throws -> Summary {
        let now = Self.ms(clock())
        let from = now - Int64(window / .milliseconds(1))
        let record = await onQueue { [self] in catalog[ref] ?? catalog.values.first { String($0.id) == ref } }
        let cid = record?.characteristicId ?? ref
        let (prior, rows) = await log.characteristicRows(cid, fromMs: from, toMs: now + 1)
        guard prior != nil || !rows.isEmpty else { throw APIError.notFound("No recent values for \(ref)") }
        var kind = record?.kind
        let type = record?.type ?? rows.last?.event.characteristic ?? prior?.event.characteristic
        if kind == nil {
            let m = await meta([cid])[cid]
            kind = SeriesKind.infer(type: type ?? "", format: m?.format, validValues: m?.validValues, min: m?.min, max: m?.max,
                                    sample: (rows.last ?? prior)?.event.value)
        }
        let up = UpSpan.from(await log.sessions())
        let row = Rollup.compute(
            kind: kind!, start: from, end: now,
            prior: prior.map { HistoryPoint(ts: $0.tsMs, json: $0.event.value) },
            points: rows.map { HistoryPoint(ts: $0.tsMs, json: $0.event.value) }, up: up
        )
        return Summary(characteristicId: cid, type: type, kind: kind!, from: from, to: now,
                       current: row.last, currentText: row.lastText, since: row.lastMs, summary: row)
    }

    // MARK: - Maintenance

    private func maintainIfDue() async {
        let now = clock()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard calendar.component(.hour, from: now) >= settings.maintenanceHour else { return }
        let day = Self.dayStamp(now, zone)
        guard await onQueue({ self.lastMaintenanceDay != day }) else { return }
        await maintain()
    }

    /// Retention and backups. Runs daily; tests call it directly.
    public func maintain() async {
        guard dir != nil else { return }
        // A closed month can still receive events archived late (after the
        // disk was away); it is backed up once nothing older is waiting.
        let waiting = await log.oldestUnarchivedMs() ?? .max
        await onQueue { [self] in
            guard openCold(), let db = rollups else { return }
            lastMaintenanceDay = Self.dayStamp(clock(), zone)
            let now = Self.ms(clock())
            do {
                let cutoff5m = now - Int64(settings.fiveMinuteDays) * 86_400_000
                // Back up first, so a month is always copied before it can be removed.
                try backup(now: now, settledBefore: waiting)
                try db.run("DELETE FROM rollup_5m WHERE bucket_ms < ?", [.int(cutoff5m)])
                try expireRawMonths(now: now)
            } catch {
                failed(error)
            }
        }
    }

    /// Deletes whole monthly files past retention, but only once their hourly
    /// rollups account for every sample in them.
    private func expireRawMonths(now: Int64) throws {
        guard let dir, let db = rollups else { return }
        let rawDir = dir.appending(path: "history/raw")
        let oldestKept = Self.monthsBack(Self.month(now), settings.rawMonths)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: rawDir.path)) ?? []
        for file in files.sorted() where file.hasSuffix(".sqlite") {
            let month = String(file.dropLast(".sqlite".count))
            guard month < oldestKept, let raw = try monthDB(month, create: false) else { continue }
            if let backups, !FileManager.default.fileExists(atPath: backups.appending(path: "raw/\(file)").path) {
                logger("History: keeping raw \(month) until it has a backup copy")
                continue
            }
            let (start, end) = Self.monthRange(month)
            let samples = try raw.scalar("SELECT COUNT(*) FROM samples") ?? 0
            let rolled = try db.scalar("SELECT COALESCE(SUM(n), 0) FROM rollup_1h WHERE bucket_ms >= ? AND bucket_ms < ?", [.int(start), .int(end)]) ?? 0
            guard samples == rolled else {
                logger("History: keeping raw \(month): \(samples) samples but hourly rollups count \(rolled)")
                continue
            }
            months[month] = nil
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: rawDir.appending(path: file + suffix))
            }
            logger("History: removed raw \(month) (\(samples) samples, kept as rollups)")
        }
    }

    /// Copies the rollups and the current month to the internal disk (kept
    /// `backupsKept` days), and each closed month once.
    private func backup(now: Int64, settledBefore: Int64) throws {
        guard let backups, let db = rollups else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: backups.appending(path: "raw"), withIntermediateDirectories: true)
        let stamp = Self.dayStamp(Date(timeIntervalSince1970: Double(now) / 1000), zone)
        let current = Self.month(now)
        func vacuum(_ source: SQLiteDB, to url: URL) throws {
            guard !fm.fileExists(atPath: url.path) else { return }
            try source.run("VACUUM INTO ?", [.text(url.path)])
        }
        try vacuum(db, to: backups.appending(path: "rollups-\(stamp).sqlite"))
        if let raw = try monthDB(current, create: false) {
            try vacuum(raw, to: backups.appending(path: "raw-current-\(stamp).sqlite"))
        }
        if let dir {
            let files = (try? fm.contentsOfDirectory(atPath: dir.appending(path: "history/raw").path)) ?? []
            for file in files where file.hasSuffix(".sqlite") && String(file.dropLast(7)) < current {
                guard Self.monthRange(String(file.dropLast(7))).1 <= settledBefore else { continue }
                let target = backups.appending(path: "raw/\(file)")
                if !fm.fileExists(atPath: target.path), let raw = try monthDB(String(file.dropLast(7)), create: false) {
                    try vacuum(raw, to: target)
                }
            }
        }
        let dated = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasSuffix(".sqlite") }
        for prefix in ["rollups-", "raw-current-"] {
            let mine = dated.filter { $0.hasPrefix(prefix) }.sorted()
            for old in mine.dropLast(settings.backupsKept) {
                try? fm.removeItem(at: backups.appending(path: old))
            }
        }
    }

    // MARK: - Helpers

    private func onQueueThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private static func rollupRow(_ s: SQLiteDB.Statement) -> RollupRow {
        func real(_ i: Int32) -> Double? { s.isNull(i) ? nil : s.real(i) }
        let states = s.text(11).flatMap { try? JSONDecoder().decode([String: Double].self, from: Data($0.utf8)) }
        return RollupRow(bucket: s.int(0), n: Int(s.int(1)), coverage: s.real(2), min: real(3), max: real(4), mean: real(5),
                         last: real(6), lastText: s.text(7), lastMs: s.isNull(8) ? nil : s.int(8), on: real(9),
                         transitions: Int(s.int(10)), states: states)
    }

    /// The device a path is on, to tell a mounted volume from its empty mount point.
    static func device(_ path: String) -> UInt64? {
        var info = stat()
        return stat(path, &info) == 0 ? UInt64(info.st_dev) : nil
    }

    static let origins = ["notification", "poll", "sample", "write", "scene"]
    static func originCode(_ origin: String?) -> Int64 { origins.firstIndex(of: origin ?? "").map { Int64($0 + 1) } ?? 0 }
    static func originName(_ code: Int64) -> String? { code >= 1 && code <= origins.count ? origins[Int(code) - 1] : nil }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func iso(_ ms: Int64) -> String { Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.iso8601) }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `YYYY-MM` of a time, in UTC.
    static func month(_ ms: Int64) -> String {
        let c = utc.dateComponents([.year, .month], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    static func monthRange(_ month: String) -> (Int64, Int64) {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let start = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))!
        let end = utc.date(byAdding: .month, value: 1, to: start)!
        return (ms(start), ms(end))
    }

    static func previousMonth(_ month: String) -> String { monthsBack(month, 1) }

    static func monthsBack(_ month: String, _ n: Int) -> String {
        let start = Date(timeIntervalSince1970: Double(monthRange(month).0) / 1000)
        return Self.month(ms(utc.date(byAdding: .month, value: -n, to: start)!))
    }

    static func months(from: Int64, to: Int64) -> [String] {
        guard to >= from else { return [] }
        var out = [month(from)]
        let last = month(to)
        while out.last! < last, out.count < 400 { out.append(month(monthRange(out.last!).1)) }
        return out
    }

    static func dayStamp(_ date: Date, _ zone: TimeZone) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }
}
