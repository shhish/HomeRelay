import Foundation
import Testing
@testable import HomeRelayCore

struct HistoryRegressionTests {
    @Test func rawTailKeepsDistinctSequencesAtTheSameMillisecond() async throws {
        let f = try HistoryFixture()
        let start = f.now
        f.temperature(20)
        await f.history.archive()
        // Same timestamp, origin and value as the archived event: still a new event.
        f.temperature(20)
        f.temperature(21)
        let response = try await f.history.query(["C-TEMP"], from: start - 1, to: start + 1, step: "raw")
        #expect(response.series[0].points?.map(\.value) == [20, 20, 21])
        await f.history.archive()
        let archived = try await f.history.query(["C-TEMP"], from: start - 1, to: start + 1, step: "raw")
        #expect(archived.series[0].points == response.series[0].points)
    }

    @Test func legacyColdStoresDeduplicateBySeqWithoutLosingRepeatedValues() async throws {
        let f = try HistoryFixture()
        f.temperature(20)
        await f.history.archive()
        let db = try SQLiteDB(path: f.disk.appending(path: "history/rollups.sqlite").path)
        try db.run("DELETE FROM meta WHERE key = 'archived_seq'")
        f.temperature(20)
        let response = try await f.history.query(["C-TEMP"], from: f.now - 1, to: f.now + 1, step: "raw")
        #expect(response.series[0].points?.map(\.value) == [20, 20])
    }

    @Test func backupsReplaceIncompleteFinalsAndCleanInterruptedTemps() async throws {
        var settings = History.Settings()
        settings.rawMonths = 1
        let f = try HistoryFixture(settings: settings)
        f.temperature(20)
        await f.history.archive()
        f.clock.advance(62 * 86_400)
        f.temperature(21)
        await f.history.archive()
        let rawBackups = f.backupDir.appending(path: "raw")
        try FileManager.default.createDirectory(at: rawBackups, withIntermediateDirectories: true)
        let target = rawBackups.appending(path: "2026-10.sqlite")
        try Data("interrupted backup".utf8).write(to: target)
        let temps = [f.backupDir, rawBackups].flatMap { directory in
            [".tmp", ".tmp-journal", ".tmp-wal", ".tmp-shm"].map {
                directory.appending(path: ".homerelay-backup-interrupted" + $0)
            }
        }
        for temp in temps { try Data("incomplete".utf8).write(to: temp) }

        await f.history.maintain()
        let backup = try SQLiteDB(path: target.path, readOnly: true)
        #expect(try backup.quickCheck())
        #expect(try backup.scalar("SELECT completed FROM homerelay_backup WHERE store_id = ?", [.text(f.log.storeId)]) == 1)
        #expect(try backup.scalar("SELECT COUNT(*) FROM samples") == 1)
        #expect(FileManager.default.fileExists(atPath: f.disk.appending(path: "history/raw/2026-10.sqlite").path) == false)
        for temp in temps { #expect(FileManager.default.fileExists(atPath: temp.path) == false) }
    }

    @Test func failedBackupPublicationCannotAuthorizeRetention() async throws {
        var settings = History.Settings()
        settings.rawMonths = 1
        let f = try HistoryFixture(settings: settings)
        f.temperature(20)
        await f.history.archive()
        f.clock.advance(62 * 86_400)
        f.temperature(21)
        await f.history.archive()
        // An existing directory satisfies fileExists but cannot be replaced by
        // the backup's final file. The original must survive this failure.
        let target = f.backupDir.appending(path: "raw/2026-10.sqlite")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        await f.history.maintain()
        #expect(FileManager.default.fileExists(atPath: f.disk.appending(path: "history/raw/2026-10.sqlite").path))
        #expect(await f.history.status().cold == .failing)
        // A failure must be retryable, including on the same day.
        try FileManager.default.removeItem(at: target)
        await f.history.maintain()
        let backup = try SQLiteDB(path: target.path, readOnly: true)
        #expect(try backup.quickCheck())
        #expect(FileManager.default.fileExists(atPath: f.disk.appending(path: "history/raw/2026-10.sqlite").path) == false)
    }

    @Test func rawQueriesStopBeforeReadingPastTheLimit() async throws {
        let f = try HistoryFixture()
        f.temperature(20)
        await f.history.archive()
        let series = try #require(try await f.history.series().first)
        let count = History.rawPointLimit + 2
        let raw = try SQLiteDB(path: f.disk.appending(path: "history/raw/2026-10.sqlite").path)
        try raw.exec("""
            WITH RECURSIVE numbers(n) AS (SELECT 2 UNION ALL SELECT n + 1 FROM numbers WHERE n < \(count))
            INSERT INTO samples(series_id, ts_ms, value, origin, seq)
            SELECT \(series.id), \(f.now) + n, 21, 1, n FROM numbers;
            ALTER TABLE samples RENAME TO stored_samples;
            CREATE VIEW samples AS
            SELECT series_id, ts_ms,
              CASE WHEN seq > \(History.rawPointLimit + 1) THEN abs(-9223372036854775808) ELSE value END AS value,
              value_text, origin, seq FROM stored_samples;
            """)
        let cold = try SQLiteDB(path: f.disk.appending(path: "history/rollups.sqlite").path)
        try cold.run("UPDATE meta SET value = ? WHERE key = 'archived_seq'", [.text(String(count))])
        // The row after limit+1 raises a SQL error if evaluated. A LIMIT on
        // the scan stops before it, rather than truncating an unbounded array.
        let response = try await f.history.query(["C-TEMP"], from: f.now - 1, to: f.now + Int64(count) + 1, step: "raw")
        #expect(response.series[0].points?.count == History.rawPointLimit)
        #expect(response.series[0].truncated == true)
    }

    @Test func hotTailReadsHonorSequenceAndRowLimits() async throws {
        let f = try HistoryFixture()
        f.temperature(20)
        await f.history.archive()
        for _ in 0..<10 { f.temperature(21) }
        let rows = await f.log.characteristicRows("C-TEMP", fromMs: f.now - 1, toMs: f.now + 1, afterSeq: 1, limit: 3).rows
        #expect(rows.map(\.seq) == [2, 3, 4])
    }

    @Test func bridgeAndResetOriginsRoundTripWithoutRenumberingOldCodes() async throws {
        let f = try HistoryFixture()
        for origin in ["bridge", "reset"] {
            f.hub.publish(HomeEvent(type: "characteristic", accessoryId: "state:example", characteristicId: "state:example:on",
                                    characteristic: "on", value: .bool(origin == "bridge"), origin: origin))
            f.clock.advance(1)
        }
        await f.history.archive()
        let response = try await f.history.query(["state:example:on"], from: f.now - 3_000, to: f.now + 1, step: "raw")
        #expect(response.series[0].points?.map(\.origin) == ["bridge", "reset"])
        #expect(History.originCode("notification") == 1)
        #expect(History.originCode("scene") == 5)
        #expect(History.originCode("bridge") == 6)
        #expect(History.originCode("reset") == 7)
    }
}
