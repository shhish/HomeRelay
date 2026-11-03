import Foundation

/// Fans HomeKit changes out to `/api/v1/events` subscribers. Slow subscribers
/// drop their oldest buffered events rather than holding up anyone else.
public actor EventHub {
    private var subscribers: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<HomeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.remove(id) }
        }
        return stream
    }

    public func publish(_ event: HomeEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    public var subscriberCount: Int { subscribers.count }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
