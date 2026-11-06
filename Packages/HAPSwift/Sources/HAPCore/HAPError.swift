// HAPError.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPError: Error, Sendable {
    case invalidTLV
    case invalidState
    case authenticationFailed
    case unavailable
    case busy
    case readOnly
    case writeOnly
    case notFound
    case outOfRange
    case invalidValue
}
