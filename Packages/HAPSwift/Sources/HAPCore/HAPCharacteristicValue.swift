// HAPCharacteristicValue.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

public enum HAPCharacteristicValue: Sendable, Equatable {
    case bool(Bool)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case int32(Int32)
    case float(Double)
    case string(String)
    case data(Data)
    case tlv8(Data)

    /// Clamp numeric values to the given min/max bounds.
    /// Non-numeric values or nil bounds are returned unchanged.
    public func clamped(minValue: Double?, maxValue: Double?) -> HAPCharacteristicValue {
        switch self {
        case .uint8(let v):
            let clamped = Double(v)
                .clamped(min: minValue, max: maxValue)
            return .uint8(UInt8(clamped))
        case .uint16(let v):
            let clamped = Double(v)
                .clamped(min: minValue, max: maxValue)
            return .uint16(UInt16(clamped))
        case .uint32(let v):
            let clamped = Double(v)
                .clamped(min: minValue, max: maxValue)
            return .uint32(UInt32(clamped))
        case .int32(let v):
            let clamped = Double(v)
                .clamped(min: minValue, max: maxValue)
            return .int32(Int32(clamped))
        case .float(let v):
            return .float(v.clamped(min: minValue, max: maxValue))
        default:
            return self
        }
    }

    public var format: HAPFormat {
        switch self {
        case .bool: .bool
        case .uint8: .uint8
        case .uint16: .uint16
        case .uint32: .uint32
        case .int32: .int
        case .float: .float
        case .string: .string
        case .data: .data
        case .tlv8: .tlv8
        }
    }
}

// MARK: - Helpers

extension Double {
    func clamped(min minVal: Double?, max maxVal: Double?) -> Double {
        var result = self
        if let lo = minVal { result = Swift.max(result, lo) }
        if let hi = maxVal { result = Swift.min(result, hi) }
        return result
    }
}
