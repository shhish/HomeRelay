import Foundation
import Testing
@testable import HomeRelayCore

@Suite struct RollupTests {
    let always = [UpSpan(start: .min, end: .max)]

    @Test func numericMeanIsTimeWeightedAndHoldsThePrior() {
        // 10 for the first minute (held from before), 20 for the next four.
        let row = Rollup.compute(
            kind: .numeric, start: 0, end: 300_000, prior: HistoryPoint(ts: -5_000, value: 10),
            points: [HistoryPoint(ts: 60_000, value: 20)], up: always
        )
        #expect(row.n == 1)
        #expect(row.coverage == 300)
        #expect(row.mean == 18)
        #expect(row.min == 10)
        #expect(row.max == 20)
        #expect(row.last == 20)
        #expect(row.lastMs == 60_000)
        #expect(row.transitions == 1)
    }

    @Test func binaryCountsOnSecondsAndTransitions() {
        let row = Rollup.compute(
            kind: .binary, start: 0, end: 100_000, prior: HistoryPoint(ts: -1, value: 0),
            points: [HistoryPoint(ts: 10_000, value: 1), HistoryPoint(ts: 40_000, value: 0), HistoryPoint(ts: 40_000, value: 0)],
            up: always
        )
        #expect(row.on == 30)
        #expect(row.transitions == 2)
        #expect(row.mean == 0.3)
    }

    @Test func enumRecordsSecondsPerState() {
        let row = Rollup.compute(
            kind: .enumerated, start: 0, end: 60_000, prior: HistoryPoint(ts: -1, value: 1),
            points: [HistoryPoint(ts: 15_000, value: 0)], up: always
        )
        #expect(row.states == ["1": 15, "0": 45])
    }

    @Test func valuesDoNotHoldAcrossTimeHomeRelayWasDown() {
        // Down from 20 s to 50 s; the value set before the gap stops at the gap.
        let up = [UpSpan(start: -10_000, end: 20_000), UpSpan(start: 50_000, end: .max)]
        let row = Rollup.compute(
            kind: .numeric, start: 0, end: 100_000, prior: HistoryPoint(ts: -1, value: 5),
            points: [HistoryPoint(ts: 60_000, value: 7)], up: up
        )
        // 5 for 20 s, unknown 20–60 s (no value yet in the new run), 7 for 40 s.
        #expect(row.coverage == 60)
        #expect(abs(row.mean! - (5.0 * 20 + 7 * 40) / 60) < 1e-9)
    }

    @Test func emptyBucketsHoldThePreviousValue() {
        let row = Rollup.compute(kind: .numeric, start: 300_000, end: 600_000, prior: HistoryPoint(ts: 10, value: 3), points: [], up: always)
        #expect(row.n == 0)
        #expect(row.mean == 3)
        #expect(row.coverage == 300)
        let unknown = Rollup.compute(kind: .numeric, start: 0, end: 300_000, prior: nil, points: [], up: always)
        #expect(unknown.coverage == 0)
        #expect(unknown.mean == nil)
    }

    @Test func kindsFromMetadata() {
        #expect(SeriesKind.infer(type: "on", format: "bool", validValues: nil, min: nil, max: nil, sample: nil) == .binary)
        #expect(SeriesKind.infer(type: "contactSensorState", format: "uint8", validValues: [0, 1], min: 0, max: 1, sample: nil) == .binary)
        #expect(SeriesKind.infer(type: "lockCurrentState", format: "uint8", validValues: nil, min: 0, max: 3, sample: nil) == .enumerated)
        #expect(SeriesKind.infer(type: "brightness", format: "int", validValues: nil, min: 0, max: 100, sample: nil) == .numeric)
        #expect(SeriesKind.infer(type: "currentTemperature", format: "float", validValues: nil, min: nil, max: nil, sample: nil) == .numeric)
        #expect(SeriesKind.infer(type: "x", format: nil, validValues: nil, min: nil, max: nil, sample: .string("a")) == .text)
    }

    @Test func dailyBucketsFollowLocalMidnightAcrossDST() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-11-01 is the US fall-back day: 25 hours long.
        let noon = Int64(Date(timeIntervalSince1970: 1_793_548_800).timeIntervalSince1970 * 1000) // 2026-11-01T12:00:00Z
        let start = BucketStep.day.start(of: noon, in: zone)
        #expect(BucketStep.day.end(of: start, in: zone) - start == 25 * 3_600_000)
        #expect(BucketStep.hour.start(of: 3_600_001, in: zone) == 3_600_000)
    }
}

/// A history store over a temp event log and a temp "disk".
final class HistoryFixture: @unchecked Sendable {
    let clock = TestClock(Date(timeIntervalSince1970: 1_793_000_000)) // 2026-10-27
    let root = FileManager.default.temporaryDirectory.appending(path: "homerelay-history-\(UUID().uuidString)")
    var disk: URL { root.appending(path: "disk/homerelay") }
    var backupDir: URL { root.appending(path: "backups") }
    let log: EventLog
    let hub: EventHub
    var history: History!

    init(markDisk: Bool = true, settings: History.Settings = History.Settings()) throws {
        log = try EventLog(path: root.appending(path: "hot/hot.sqlite"), clock: { [clock] in clock.date })
        hub = EventHub(log: log)
        if markDisk { try mark(log.storeId) }
        let meta: SeriesMetaProvider = { ids in
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, id == "C-ON"
                    ? SeriesMeta(type: "on", format: "bool", unit: nil, validValues: nil, min: nil, max: nil)
                    : SeriesMeta(type: "currentTemperature", format: "float", unit: "celsius", validValues: nil, min: nil, max: nil))
            })
        }
        history = History(dir: disk, backups: backupDir, log: log, meta: meta, settings: settings,
                          zone: TimeZone(identifier: "UTC")!, clock: { [clock] in clock.date })
    }

    func mark(_ id: String) throws {
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        try Data(id.utf8).write(to: disk.appending(path: ".homerelay-store"))
    }

    var now: Int64 { Int64(clock.date.timeIntervalSince1970 * 1000) }

    func temperature(_ value: Double) {
        hub.publish(HomeEvent(type: "characteristic", home: "Home", accessoryId: "SENSOR-1", accessory: "Sensor", room: "Office",
                              characteristicId: "C-TEMP", characteristic: "currentTemperature", value: .double(value), origin: "notification"))
    }

    func lamp(_ on: Bool) {
        hub.publish(HomeEvent(type: "characteristic", home: "Home", accessoryId: "LAMP-1", accessory: "Desk Lamp", room: "Office",
                              characteristicId: "C-ON", characteristic: "on", value: .bool(on), origin: "notification"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct HistoryTests {
    @Test func archivesToMonthlyFilesAndMarksTheLog() async throws {
        let f = try HistoryFixture()
        f.temperature(20)
        f.clock.advance(120)
        f.temperature(22)
        f.lamp(true)
        await f.history.archive()

        let raw = try SQLiteDB(path: f.disk.appending(path: "history/raw/2026-10.sqlite").path)
        #expect(try raw.scalar("SELECT COUNT(*) FROM samples") == 3)
        #expect(await f.log.unarchived(limit: 10).isEmpty)
        #expect(await f.log.oldestUnarchivedMs() == nil)

        let series = try await f.history.series()
        #expect(series.map(\.type).sorted() == ["currentTemperature", "on"])
        #expect(series.first { $0.type == "on" }?.kind == .binary)
        #expect(series.first { $0.type == "currentTemperature" }?.unit == "celsius")
        #expect(series.first { $0.type == "on" }?.room == "Office")

        let status = await f.history.status()
        #expect(status.cold == .ok)
        #expect(status.healthy)
        #expect(status.lagS == nil)

        // Archiving again copies nothing twice.
        await f.history.archive()
        #expect(try raw.scalar("SELECT COUNT(*) FROM samples") == 3)
    }

    @Test func rollupsAndQueries() async throws {
        let f = try HistoryFixture()
        let start = f.now
        f.temperature(20)
        f.clock.advance(60)
        f.temperature(26)        // 20 for 1 min, then 26
        f.clock.advance(600)
        await f.history.archive()

        let step = try await f.history.query(["C-TEMP"], from: start, to: f.now, step: "5m")
        let buckets = try #require(step.series.first?.buckets)
        #expect(step.step == "5m")
        let first = try #require(buckets.first)
        #expect(first.n == 2)
        // Bucket starts at the 5-minute boundary at or before `start`; the
        // value only exists from `start`, so coverage is the known part.
        #expect(first.max == 26)
        // Later buckets have no events but hold 26.
        #expect(buckets.dropFirst().allSatisfy { $0.n == 0 && $0.mean == 26 })

        let raw = try await f.history.query(["C-TEMP"], from: start, to: f.now, step: "raw")
        #expect(raw.series[0].points?.map(\.value) == [20, 26])
        #expect(raw.series[0].points?.first?.origin == "notification")

        // Not yet archived values come from the event log.
        f.temperature(30)
        f.clock.advance(1)
        let fresh = try await f.history.query(["C-TEMP"], from: start, to: f.now, step: "raw")
        #expect(fresh.series[0].points?.map(\.value) == [20, 26, 30])

        let auto = try await f.history.query(["C-TEMP"], from: start - 30 * 86_400_000, to: f.now, step: "auto")
        #expect(auto.step == "1h")
        await #expect(throws: APIError.self) { try await f.history.query(["nope"], from: start, to: f.now, step: "raw") }
    }

    @Test func missingDiskWritesNothingAndRecovers() async throws {
        let f = try HistoryFixture(markDisk: false)
        f.temperature(20)
        await f.history.archive()
        #expect(!FileManager.default.fileExists(atPath: f.disk.path))
        #expect(await f.history.status().cold == .missing)
        // Kept in the event log until the disk is back.
        #expect(await f.log.unarchived(limit: 10).count == 1)
        await #expect(throws: APIError.self) { try await f.history.series() }

        f.clock.advance(7_200)
        let late = await f.history.status()
        #expect(!late.healthy)
        #expect(late.lagS == 7_200)

        try f.mark(f.log.storeId)
        await f.history.archive()
        #expect(await f.history.status().cold == .ok)
        #expect(await f.history.status().healthy)
        #expect(await f.log.unarchived(limit: 10).isEmpty)
    }

    @Test func refusesAnotherInstallsDisk() async throws {
        let f = try HistoryFixture(markDisk: false)
        try f.mark("SOMEONE-ELSE")
        f.temperature(20)
        await f.history.archive()
        #expect(await f.history.status().cold == .foreign)
        #expect(!FileManager.default.fileExists(atPath: f.disk.appending(path: "history").path))
    }

    @Test func gapsShowWhenHomeRelayWasDown() async throws {
        let f = try HistoryFixture()
        f.temperature(20)
        f.log.close()
        f.clock.advance(3_600)
        // A new run of HomeRelay on the same disks.
        let log2 = try EventLog(path: f.log.path, clock: { [clock = f.clock] in clock.date })
        let hub2 = EventHub(log: log2)
        let history2 = History(dir: f.disk, backups: f.backupDir, log: log2, zone: TimeZone(identifier: "UTC")!, clock: { [clock = f.clock] in clock.date })
        hub2.publish(HomeEvent(type: "characteristic", accessoryId: "SENSOR-1", characteristicId: "C-TEMP", characteristic: "currentTemperature", value: .double(21), origin: "sample"))
        f.clock.advance(60)
        await history2.archive()
        let r = try await history2.query(["C-TEMP"], from: f.now - 7_200_000, to: f.now, step: "raw")
        #expect(r.gaps.count == 2) // before the first run, and the hour between runs
        #expect(r.gaps.last.map { $0[1] - $0[0] } == 3_600_000)
        #expect(r.series[0].points?.count == 2)
    }

    @Test func aCrashCorrectsTheBucketsItHappenedIn() async throws {
        let f = try HistoryFixture()
        // Start of an hour, then the lamp on for 10 minutes before a crash.
        f.clock.advance(Double(3_600 - Int(f.now / 1000) % 3_600))
        let hour = f.now
        f.lamp(true)
        f.clock.advance(600)
        f.log.flush()
        await f.history.archive()
        // While running, the hour is assumed to continue (held to its end).
        // Crash: no close. Restart 20 minutes later; the old session is now known to have ended.
        f.clock.advance(1_200)
        let log2 = try EventLog(path: f.log.path, clock: { [clock = f.clock] in clock.date })
        let history2 = History(dir: f.disk, backups: f.backupDir, log: log2, zone: TimeZone(identifier: "UTC")!, clock: { [clock = f.clock] in clock.date })
        f.clock.advance(3_600)
        await history2.archive()
        let after = try await history2.query(["C-ON"], from: hour, to: hour + 3_600_000, step: "1h")
        let bucket = try #require(after.series[0].buckets?.first)
        // On only until the last heartbeat before the crash (at most 10 minutes), not the whole hour.
        #expect((bucket.on ?? 0) <= 600)
        #expect((bucket.on ?? 0) > 500)
    }

    @Test func theBucketInProgressCountsOnlyTimeSoFar() async throws {
        let f = try HistoryFixture()
        f.clock.advance(Double(3_600 - Int(f.now / 1000) % 3_600))
        let hour = f.now
        f.lamp(true)
        f.clock.advance(600)
        await f.history.archive()
        let r = try await f.history.query(["C-ON"], from: hour, to: hour + 3_600_000, step: "1h")
        let bucket = try #require(r.series[0].buckets?.first)
        #expect(bucket.on == 600)
        #expect(bucket.coverage == 600)
    }

    @Test func summaryComesFromTheEventLogEvenWithoutTheDisk() async throws {
        let f = try HistoryFixture(markDisk: false)
        f.lamp(true)
        f.clock.advance(1_800)
        f.lamp(false)
        f.clock.advance(1_800)
        let s = try await f.history.summary("C-ON", window: .seconds(3_600))
        #expect(s.kind == .binary)
        #expect(s.summary.on == 1_800)
        #expect(s.current == 0)
        #expect(s.summary.transitions == 1)
        await #expect(throws: APIError.self) { try await f.history.summary("C-NOPE", window: .seconds(60)) }
    }

    @Test func retentionDeletesVerifiedMonthsAndBacksUp() async throws {
        var settings = History.Settings()
        settings.rawMonths = 1
        let f = try HistoryFixture(settings: settings)
        f.temperature(20)
        f.clock.advance(60)
        f.temperature(21)
        await f.history.archive()
        let october = f.disk.appending(path: "history/raw/2026-10.sqlite")
        #expect(FileManager.default.fileExists(atPath: october.path))

        // Two months later, with a new value in December.
        f.clock.advance(62 * 86_400)
        f.temperature(19)
        await f.history.archive()
        await f.history.maintain()
        #expect(!FileManager.default.fileExists(atPath: october.path))
        // The hourly rollups that replaced it are still queryable.
        let rolled = try await f.history.query(["C-TEMP"], from: f.now - 63 * 86_400_000, to: f.now, step: "1d")
        #expect(rolled.series[0].buckets?.contains { $0.n == 2 } == true)

        let backups = try FileManager.default.contentsOfDirectory(atPath: f.backupDir.path)
        #expect(backups.contains { $0.hasPrefix("rollups-") })
        #expect(backups.contains { $0.hasPrefix("raw-current-") })
        let closed = try FileManager.default.contentsOfDirectory(atPath: f.backupDir.appending(path: "raw").path)
        // October was backed up before it was removed.
        #expect(closed.contains("2026-10.sqlite"))
    }

    @Test func historyRoutes() async throws {
        let f = try HistoryFixture()
        f.temperature(20)
        await f.history.archive()
        let server = try await TestServer(events: f.hub, history: f.history)
        let (status, data) = try await server.request("GET", "/api/v1/history/series", token: TestServer.read)
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("C-TEMP"))
        let to = f.now + 1
        #expect(try await server.request("GET", "/api/v1/history?series=C-TEMP&from=\(to - 60_000)&to=\(to)&step=raw", token: TestServer.read).0 == 200)
        #expect(try await server.request("GET", "/api/v1/history?series=C-TEMP&from=2026-10-27T00:00:00Z", token: TestServer.read).0 == 200)
        #expect(try await server.request("GET", "/api/v1/history", token: TestServer.read).0 == 400)
        #expect(try await server.request("GET", "/api/v1/history?series=C-TEMP&from=yesterday", token: TestServer.read).0 == 400)
        #expect(try await server.request("GET", "/api/v1/history/summary?series=C-TEMP&window=2h", token: TestServer.read).0 == 200)
        #expect(try await server.request("GET", "/api/v1/history/summary?series=C-TEMP&window=30d", token: TestServer.read).0 == 400)
        let (healthStatus, health) = try await server.request("GET", "/api/v1/health/history", token: nil)
        #expect(healthStatus == 200)
        #expect(try server.object(health)["cold"] == .string("ok"))
        let (_, main) = try await server.request("GET", "/api/v1/health", token: nil)
        #expect(try server.object(main)["history"] != nil)
    }

    @Test func strictHealthFailsWhenHomeKitIsNotReady() async throws {
        let server = try await TestServer()
        #expect(try await server.request("GET", "/api/v1/health/ready", token: nil).0 == 200)
        await server.home.setReady(false)
        #expect(try await server.request("GET", "/api/v1/health/ready", token: nil).0 == 503)
        #expect(try await server.request("GET", "/api/v1/health", token: nil).0 == 200)
    }
}
