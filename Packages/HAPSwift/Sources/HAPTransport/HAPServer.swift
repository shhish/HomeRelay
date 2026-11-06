// HAPServer.swift
// Copyright 2026 Monagle Pty Ltd

import HAPCore

// MARK: - HAPServer

public protocol HAPServer: Sendable {
    func start(port: UInt16) async throws
    func stop() async
    var port: UInt16 { get async }
}

// MARK: - HAPServerDelegate

public protocol HAPServerDelegate: Sendable {
    func server(_ server: any HAPServer, didReceiveRead aid: UInt64, iid: UInt64) async -> HAPCharacteristicValue?
    func server(_ server: any HAPServer, didReceiveWrite aid: UInt64, iid: UInt64, value: HAPCharacteristicValue) async throws
    func server(_ server: any HAPServer, didReceiveIdentify aid: UInt64) async throws
}
