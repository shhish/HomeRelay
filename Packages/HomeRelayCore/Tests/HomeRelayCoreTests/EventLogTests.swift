import Foundation
import Synchronization
import Testing
@testable import HomeRelayCore

/// A clock tests can move.
final class TestClock: Sendable {
    private let now: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { now = Mutex(start) }
    var date: Date { now.withLock { $0 } }
    func advance(_ seconds: Double) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func tempLogURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "homerelay-log-\(UUID().uuidString)/hot.sqlite")
}

func lamp(_ on: Bool, origin: String = "notification") -> HomeEvent {
    HomeEvent(type: "characteristic", accessoryId: "LAMP-1", characteristicId: "C-ON", characteristic: "on", value: .bool(on), origin: origin)
}

@Suite struct EventLogTests {
    @Test func numbersEventsAndReadsBackFromDiskAndQueue() async throws {
        let log = try EventLog(path: tempLogURL())
        let first = log.append(lamp(true))
        let second = log.append(lamp(false))
        #expect(first.seq == 1)
        #expect(second.seq == 2)
        // Not flushed yet: the queue answers.
        #expect(await log.events(after: 0).map(\.seq) == [1, 2])
        log.flush()
        _ = log.append(lamp(true))
        // Two on disk, one queued, in order.
        let all = await log.events(after: 0)
        #expect(all.map(\.seq) == [1, 2, 3])
        #expect(all[1].value == .bool(false))
        #expect(all[0].origin == "notification")
        #expect(await log.events(after: 2).map(\.seq) == [3])
        #expect(await log.events(after: 0, limit: 2).map(\.seq) == [1, 2])
    }

    @Test func seqKeepsIncreasingAcrossRestartsAndSessionsAreRecorded() async throws {
        let url = tempLogURL()
        var store: String
        do {
            let log = try EventLog(path: url)
            store = log.storeId
            _ = log.append(lamp(true))
            _ = log.append(lamp(false))
            log.close()
        }
        do {
            // Clean stop before: numbering continues.
            let log = try EventLog(path: url)
            #expect(log.storeId == store)
            #expect(log.append(lamp(true)).seq == 3)
            log.flush()
            // Then a crash: no close().
        }
        let log = try EventLog(path: url)
        // Skipped past numbers the crashed run may have streamed but not written.
        #expect(log.latestSeq == 3 + EventLog.uncleanSkip)
        let stats = await log.stats()
        #expect(stats.rows == 3)
        #expect(stats.sessions == 3)
        let db = try SQLiteDB(path: url.path)
        #expect(try db.scalar("SELECT COUNT(*) FROM sessions WHERE reason = 'unclean'") == 1)
        #expect(try db.scalar("SELECT COUNT(*) FROM sessions WHERE reason = 'stopped'") == 1)
    }

    @Test func retentionKeepsUnarchivedRowsAndNeverReusesNumbers() async throws {
        let clock = TestClock()
        var settings = EventLog.Settings()
        settings.retention = .seconds(3_600)
        let url = tempLogURL()
        let log = try EventLog(path: url, settings: settings, clock: { clock.date })
        _ = log.append(lamp(true))
        _ = log.append(lamp(false))
        log.flush()
        let db = try SQLiteDB(path: url.path)
        try db.run("UPDATE events SET archived = 1 WHERE seq = 1")
        clock.advance(7_200)
        log.maintain()
        // Archived and old: gone. Unarchived: kept until archived.
        #expect(await log.events(after: 0).map(\.seq) == [2])
        try db.run("UPDATE events SET archived = 1")
        log.maintain()
        #expect(await log.events(after: 0).isEmpty)
        #expect(await log.oldestSeq() == nil)
        log.close()
        let reopened = try EventLog(path: url, settings: settings, clock: { clock.date })
        #expect(reopened.append(lamp(true)).seq == 3)
    }

    @Test func sizeCapDropsOldestAndCountsThem() async throws {
        var settings = EventLog.Settings()
        settings.maxBytes = 64 * 1024
        let log = try EventLog(path: tempLogURL(), settings: settings)
        for i in 0..<2_000 { _ = log.append(lamp(i % 2 == 0)) }
        log.flush()
        log.maintain()
        let stats = await log.stats()
        #expect(stats.dropped > 0)
        #expect(stats.bytes <= 64 * 1024)
        #expect(stats.latestSeq == 2_000)
        #expect((stats.oldestSeq ?? 0) > 1)
    }

    @Test func statsCountByTypeAndOrigin() async throws {
        let log = try EventLog(path: tempLogURL())
        _ = log.append(lamp(true))
        _ = log.append(lamp(false, origin: "write"))
        _ = log.append(lamp(false, origin: "sample"))
        _ = log.append(HomeEvent(type: "reachability", accessoryId: "LAMP-1", reachable: false))
        let stats = await log.stats()
        #expect(stats.byType == ["characteristic": 3, "reachability": 1])
        #expect(stats.byOrigin == ["notification": 1, "write": 1, "sample": 1])
        // Counted before stats writes the queue out.
        #expect(stats.pending == 4)
    }

    @Test func hubNumbersLogsAndStreamsInOrder() async throws {
        let hub = EventHub(log: try EventLog(path: tempLogURL()))
        let stream = hub.subscribe()
        hub.publish(lamp(true))
        hub.record(lamp(true, origin: "sample"))
        hub.publish(lamp(false))
        var iterator = stream.makeAsyncIterator()
        let a = await iterator.next()
        let b = await iterator.next()
        #expect(a?.event.seq == 1)
        #expect(a?.previous == nil)
        // The sample is logged but not streamed; previous still points at the last streamed event.
        #expect(b?.event.seq == 3)
        #expect(b?.previous == 1)
        #expect(await hub.log!.events(after: 0).map(\.seq) == [1, 2, 3])
    }

    @Test func causeHeaderValidation() {
        #expect(RequestContext.validCause("routine:hall/run-42") == "routine:hall/run-42")
        #expect(RequestContext.validCause("has space") == nil)
        #expect(RequestContext.validCause(String(repeating: "x", count: 200)) == nil)
        #expect(RequestContext.validCause("") == nil)
        #expect(RequestContext.validCause(nil) == nil)
    }
}
