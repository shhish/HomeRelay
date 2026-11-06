// HAPServiceType+Extended.swift
// Copyright 2026 Monagle Pty Ltd

// MARK: - Lightbulb & Power

extension HAPServiceType {
    public static let lightbulb = HAPServiceType(rawValue: "43")
    public static let `switch` = HAPServiceType(rawValue: "49")
    public static let outlet = HAPServiceType(rawValue: "47")
}

// MARK: - Climate & Comfort

extension HAPServiceType {
    public static let fanV2 = HAPServiceType(rawValue: "B7")
    public static let thermostat = HAPServiceType(rawValue: "4A")
}

// MARK: - Security & Access

extension HAPServiceType {
    public static let doorLock = HAPServiceType(rawValue: "45")
    public static let windowCovering = HAPServiceType(rawValue: "8C")
}

// MARK: - Sensors

extension HAPServiceType {
    public static let motionSensor = HAPServiceType(rawValue: "85")
    public static let temperatureSensor = HAPServiceType(rawValue: "8A")
    public static let humiditySensor = HAPServiceType(rawValue: "82")
    public static let contactSensor = HAPServiceType(rawValue: "80")
    public static let leakSensor = HAPServiceType(rawValue: "83")
    public static let smokeSensor = HAPServiceType(rawValue: "87")
    public static let carbonMonoxideSensor = HAPServiceType(rawValue: "7F")
    public static let occupancySensor = HAPServiceType(rawValue: "86")
}

// MARK: - Media

extension HAPServiceType {
    public static let speaker = HAPServiceType(rawValue: "113")
}
