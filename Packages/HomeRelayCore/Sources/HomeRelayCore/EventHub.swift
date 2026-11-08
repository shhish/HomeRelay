import Foundation
import Synchronization

/// One event as a subscriber receives it. `previous` is the `seq` of the event
/// fanned out just before this one, so a subscriber whose buffer overflowed can
/// tell it missed something and fetch it from the log.
public struct HubItem: Sendable {
    public var event: HomeEvent
    public var previous: Int64?
}

/// Records each event in the log first (which numbers it), then fans it out to
/// `/api/v1/events` subscribers, all under one lock so subscribers see events
/// in `seq` order. A slow subscriber drops its oldest buffered events rather
/// than holding up anyone else; with a log it can recover them from there.
public final class EventHub: Sendable {
    public let log: EventLog?

    private struct State {
        var subscribers: [UUID: AsyncStream<HubItem>.Continuation] = [:]
        var lastPublished: Int64?
    }
    private let state = Mutex(State())

    public init(log: EventLog? = nil) {
        self.log = log
    }

    public func subscribe() -> AsyncStream<HubItem> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HubItem>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { $0.subscribers[id] = continuation }
        return stream
    }

    /// Logs `event`, streams it, and returns it numbered.
    @discardableResult
    public func publish(_ event: HomeEvent) -> HomeEvent {
        state.withLock { s in
            let numbered = log?.append(event) ?? event
            // An exhausted/unwritable reservation must not leak an unreserved
            // sequence (or an unresumable live event) to subscribers.
            if log != nil && numbered.seq == nil { return numbered }
            let item = HubItem(event: numbered, previous: s.lastPublished)
            s.lastPublished = numbered.seq
            for continuation in s.subscribers.values { continuation.yield(item) }
            return numbered
        }
    }

    /// Logs `event` without streaming it (periodic samples for history).
    @discardableResult
    public func record(_ event: HomeEvent) -> HomeEvent {
        log?.append(event) ?? event
    }

    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}
