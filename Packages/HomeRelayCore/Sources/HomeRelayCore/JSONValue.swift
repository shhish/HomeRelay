import Foundation

/// A JSON value that round-trips through Codable. Used for characteristic values
/// and request bodies, where the shape depends on the device.
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// Numeric view of the value, if it has one. Bools count as 0/1.
    public var doubleValue: Double? {
        switch self {
        case .int(let v): Double(v)
        case .double(let v): v
        case .bool(let v): v ? 1 : 0
        default: nil
        }
    }

    /// Truthiness for on/off style values. Strings accept the usual spellings.
    public var boolValue: Bool? {
        switch self {
        case .bool(let v): v
        case .int(let v): v != 0
        case .double(let v): v != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "on", "yes", "1": true
            case "false", "off", "no", "0": false
            default: nil
            }
        default: nil
        }
    }
}
