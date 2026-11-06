import Foundation

/// How a recorded characteristic is summarised.
public enum SeriesKind: String, Codable, Sendable {
    /// Temperature, humidity, brightness, power: time-weighted mean, min, max.
    case numeric
    /// Motion, contact, on/off, leak: seconds on and transitions.
    case binary
    /// Lock state, door state, heating mode: seconds in each state.
    case enumerated = "enum"
    /// Strings: count and last value only.
    case text

    /// Characteristic types that are states even when HomeKit gives no valid-values list.
    static let enumTypes: Set<String> = [
        // HomeRelay's names (HomeKitNames.swift), not Apple's.
        "doorState", "doorTarget", "lockState", "lockTarget", "currentHeatingCooling", "targetHeatingCooling",
        "temperatureUnits", "airQuality", "purifierState", "purifierMode", "positionState", "fanState", "fanMode",
        "charging", "swing", "rotationDirection", "currentHeaterCoolerState", "targetHeaterCoolerState",
        "currentHumidifierDehumidifierState", "targetHumidifierDehumidifierState", "securitySystemCurrentState",
        "securitySystemTargetState", "currentSlatState", "programMode", "buttonEvent",
    ]

    /// Picks a kind from HomeKit metadata, falling back to the value's own type.
    public static func infer(type: String, format: String?, validValues: [Int]?, min: Double?, max: Double?, sample: JSONValue?) -> SeriesKind {
        switch format {
        case "bool": return .binary
        case "string", "data", "tlv8": return .text
        case "float": return .numeric
        default: break
        }
        if let values = validValues, !values.isEmpty {
            return Set(values).isSubset(of: [0, 1]) ? .binary : .enumerated
        }
        if enumTypes.contains(type) { return .enumerated }
        if format != nil, min == 0, max == 1 { return .binary }
        switch sample {
        case .bool: return .binary
        case .string, .array, .object: return .text
        default: return .numeric
        }
    }
}

/// One recorded value. `value` is numeric (booleans as 0 and 1); `text` holds
/// strings. Both nil means the value was unknown.
public struct HistoryPoint: Sendable, Equatable {
    public var ts: Int64
    public var value: Double?
    public var text: String?

    public init(ts: Int64, value: Double?, text: String? = nil) {
        self.ts = ts
        self.value = value
        self.text = text
    }

    public init(ts: Int64, json: JSONValue?) {
        self.ts = ts
        switch json {
        case .bool(let b): value = b ? 1 : 0
        case .int(let i): value = Double(i)
        case .double(let d): value = d
        case .string(let s): text = s
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            text = json.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        case .null, nil: break
        }
    }
}

/// A stretch of time HomeRelay was running; values are only known inside one.
public struct UpSpan: Sendable, Equatable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    /// Spans from the session table. A session still open (or not yet known to
    /// have ended) is taken to run on; when its end is learned, buckets after
    /// it are recomputed.
    public static func from(_ sessions: [EventLog.Session]) -> [UpSpan] {
        sessions.map { UpSpan(start: $0.startedMs, end: $0.stoppedMs ?? .max) }.sorted { $0.start < $1.start }
    }
}

/// A summary of one series over one bucket.
public struct RollupRow: Codable, Sendable, Equatable {
    public var bucket: Int64
    /// Values recorded inside the bucket.
    public var n: Int
    /// Seconds the value was known (HomeRelay running and a value in force).
    public var coverage: Double
    public var min: Double?
    public var max: Double?
    /// Time-weighted mean over the covered seconds.
    public var mean: Double?
    /// The value in force at the end of the bucket, and when it was recorded.
    public var last: Double?
    public var lastText: String?
    public var lastMs: Int64?
    /// Binary series: seconds on.
    public var on: Double?
    /// Changes of value inside the bucket.
    public var transitions: Int
    /// Enum series: seconds in each state, keyed by the state's number.
    public var states: [String: Double]?
}

public enum Rollup {
    /// Summarises `[start, end)` with step-hold semantics: each value holds
    /// until the next one, but never past the end of the HomeRelay run it was
    /// recorded in. `prior` is the last value before `start`; `points` are
    /// sorted and lie inside the bucket.
    public static func compute(
        kind: SeriesKind, start: Int64, end: Int64, prior: HistoryPoint?, points: [HistoryPoint], up: [UpSpan]
    ) -> RollupRow {
        var row = RollupRow(bucket: start, n: points.count, coverage: 0, transitions: 0)
        var coveredMs: Int64 = 0
        var integral = 0.0
        var onMs: Int64 = 0
        var stateMs: [String: Int64] = [:]

        func hold(_ point: HistoryPoint?, from: Int64, to: Int64) {
            guard let point, to > from, let span = up.first(where: { $0.start <= point.ts && point.ts < $0.end }) else { return }
            let covered = Swift.max(0, Swift.min(to, span.end) - Swift.max(from, span.start))
            guard covered > 0 else { return }
            if kind == .text {
                if point.text != nil || point.value != nil { coveredMs += covered }
                return
            }
            guard let v = point.value else { return }
            coveredMs += covered
            integral += v * Double(covered)
            row.min = Swift.min(row.min ?? v, v)
            row.max = Swift.max(row.max ?? v, v)
            switch kind {
            case .binary: if v >= 0.5 { onMs += covered }
            case .enumerated: stateMs[String(Int(v.rounded())), default: 0] += covered
            default: break
            }
        }

        var current = prior
        var from = start
        var previous = prior.map { ($0.value, $0.text) }
        for point in points {
            hold(current, from: from, to: point.ts)
            if kind != .text, let v = point.value {
                row.min = Swift.min(row.min ?? v, v)
                row.max = Swift.max(row.max ?? v, v)
            }
            if let p = previous, p != (point.value, point.text), point.value != nil || point.text != nil {
                row.transitions += 1
            }
            if point.value != nil || point.text != nil { previous = (point.value, point.text) }
            current = point
            from = Swift.max(from, point.ts)
        }
        hold(current, from: from, to: end)

        let lastPoint = points.last ?? prior
        row.last = lastPoint?.value
        row.lastText = lastPoint?.text
        row.lastMs = lastPoint?.ts
        row.coverage = Double(coveredMs) / 1000
        if kind != .text, coveredMs > 0 { row.mean = integral / Double(coveredMs) }
        if kind == .text { row.min = nil; row.max = nil }
        if kind == .binary { row.on = Double(onMs) / 1000 }
        if kind == .enumerated, !stateMs.isEmpty { row.states = stateMs.mapValues { Double($0) / 1000 } }
        return row
    }
}

/// Bucket boundaries. 5-minute and hourly buckets align to UTC; daily buckets
/// start at local midnight, so a day can be 23 or 25 hours long.
public enum BucketStep: String, Sendable, CaseIterable {
    case fiveMinutes = "5m"
    case hour = "1h"
    case day = "1d"

    var table: String {
        switch self {
        case .fiveMinutes: "rollup_5m"
        case .hour: "rollup_1h"
        case .day: "rollup_1d"
        }
    }

    public func start(of ms: Int64, in zone: TimeZone) -> Int64 {
        switch self {
        case .fiveMinutes: return Self.floor(ms, 300_000)
        case .hour: return Self.floor(ms, 3_600_000)
        case .day:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(ms) / 1000))
            return Int64((day.timeIntervalSince1970 * 1000).rounded())
        }
    }

    public func end(of bucketStart: Int64, in zone: TimeZone) -> Int64 {
        switch self {
        case .fiveMinutes: return bucketStart + 300_000
        case .hour: return bucketStart + 3_600_000
        case .day:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let next = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: Double(bucketStart) / 1000))!
            return Int64((next.timeIntervalSince1970 * 1000).rounded())
        }
    }

    /// Nominal length, for choosing a step.
    var nominalMs: Int64 {
        switch self {
        case .fiveMinutes: 300_000
        case .hour: 3_600_000
        case .day: 86_400_000
        }
    }

    private static func floor(_ ms: Int64, _ size: Int64) -> Int64 {
        ms >= 0 ? ms / size * size : ((ms + 1) / size - 1) * size
    }
}
