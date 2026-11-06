// HAPFormat.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPFormat: String, Sendable, Codable {
    case bool
    case uint8
    case uint16
    case uint32
    /// Signed 32-bit integer. HAP spec wire format is `"int"`.
    case int
    case float
    case string
    case data
    case tlv8
}
