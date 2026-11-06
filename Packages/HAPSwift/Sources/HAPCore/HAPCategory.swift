// HAPCategory.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPCategory: UInt8, Sendable {
    case other = 1
    case bridge = 2
    case fan = 3
    case garageDoorOpener = 4
    case doorLock = 6
    case outlet = 7
    case `switch` = 8
    case thermostat = 9
    case sensor = 10
    case securitySystem = 11
    case windowCovering = 14
    case programmableSwitch = 15
    case speaker = 26
}
