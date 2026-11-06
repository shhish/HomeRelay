// HAPPairingError.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPPairingError: Error, Sendable {
    case invalidState
    case invalidMethod
    case authenticationFailed
    case maxPeers
    case maxTries
    case unavailable
}

/// kTLVError codes used in TLV8 error responses during pairing.
public enum TLV8ErrorCode: UInt8, Sendable {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}
