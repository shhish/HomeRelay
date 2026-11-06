// HAPService+Factories.swift
// Copyright 2026 Monagle Pty Ltd

// MARK: - Lightbulb & Power

extension HAPService {
    public static func lightbulb(
        startIID: UInt64,
        supportsBrightness: Bool = true,
        supportsColorTemperature: Bool = false,
        supportsColor: Bool = false
    ) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .on, value: .bool(false),
            permissions: [.read, .write, .notify], format: .bool
        )); iid += 1

        if supportsBrightness {
            chars.append(HAPCharacteristic(
                iid: iid, type: .brightness, value: .int32(100),
                permissions: [.read, .write, .notify], format: .int,
                minValue: 0, maxValue: 100, minStep: 1,
                unit: .percentage
            )); iid += 1
        }

        if supportsColor {
            chars.append(HAPCharacteristic(
                iid: iid, type: .hue, value: .float(0),
                permissions: [.read, .write, .notify], format: .float,
                minValue: 0, maxValue: 360, minStep: 1,
                unit: .arcdegrees
            )); iid += 1

            chars.append(HAPCharacteristic(
                iid: iid, type: .saturation, value: .float(0),
                permissions: [.read, .write, .notify], format: .float,
                minValue: 0, maxValue: 100, minStep: 1,
                unit: .percentage
            )); iid += 1
        }

        if supportsColorTemperature {
            chars.append(HAPCharacteristic(
                iid: iid, type: .colorTemperature, value: .int32(250),
                permissions: [.read, .write, .notify], format: .int,
                minValue: 140, maxValue: 500, minStep: 1
            )); iid += 1
        }

        return HAPService(type: .lightbulb, characteristics: chars)
    }

    public static func `switch`(startIID: UInt64) -> HAPService {
        HAPService(type: .switch, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .on, value: .bool(false),
                permissions: [.read, .write, .notify], format: .bool
            ),
        ])
    }

    public static func outlet(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .on, value: .bool(false),
            permissions: [.read, .write, .notify], format: .bool
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .outletInUse, value: .bool(false),
            permissions: [.read, .notify], format: .bool
        ))

        return HAPService(type: .outlet, characteristics: chars)
    }
}

// MARK: - Climate & Comfort

extension HAPService {
    public static func fanV2(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .active, value: .uint8(0),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 1
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .rotationSpeed, value: .float(0),
            permissions: [.read, .write, .notify], format: .float,
            minValue: 0, maxValue: 100, minStep: 1,
            unit: .percentage
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .rotationDirection, value: .int32(0),
            permissions: [.read, .write, .notify], format: .int,
            minValue: 0, maxValue: 1
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .swingMode, value: .uint8(0),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 1
        ))

        return HAPService(type: .fanV2, characteristics: chars)
    }

    public static func thermostat(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .currentTemperature, value: .float(20),
            permissions: [.read, .notify], format: .float,
            minValue: 0, maxValue: 100, minStep: 0.1,
            unit: .celsius
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .targetTemperature, value: .float(20),
            permissions: [.read, .write, .notify], format: .float,
            minValue: 10, maxValue: 38, minStep: 0.1,
            unit: .celsius
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .currentHeatingCoolingState, value: .uint8(0),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 2
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .targetHeatingCoolingState, value: .uint8(0),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 3
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .currentRelativeHumidity, value: .float(50),
            permissions: [.read, .notify], format: .float,
            minValue: 0, maxValue: 100, minStep: 1,
            unit: .percentage
        ))

        return HAPService(type: .thermostat, characteristics: chars)
    }
}

// MARK: - Security & Access

extension HAPService {
    public static func doorLock(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .lockCurrentState, value: .uint8(3),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 3
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .lockTargetState, value: .uint8(1),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 1
        ))

        return HAPService(type: .doorLock, characteristics: chars)
    }

    public static func windowCovering(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .currentPosition, value: .uint8(0),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 100, minStep: 1,
            unit: .percentage
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .targetPosition, value: .uint8(0),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 100, minStep: 1,
            unit: .percentage
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .positionState, value: .uint8(2),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 2
        ))

        return HAPService(type: .windowCovering, characteristics: chars)
    }
}

// MARK: - Sensors

extension HAPService {
    public static func motionSensor(startIID: UInt64) -> HAPService {
        HAPService(type: .motionSensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .motionDetected, value: .bool(false),
                permissions: [.read, .notify], format: .bool
            ),
        ])
    }

    public static func temperatureSensor(startIID: UInt64) -> HAPService {
        HAPService(type: .temperatureSensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .currentTemperature, value: .float(20),
                permissions: [.read, .notify], format: .float,
                minValue: 0, maxValue: 100, minStep: 0.1,
                unit: .celsius
            ),
        ])
    }

    public static func humiditySensor(startIID: UInt64) -> HAPService {
        HAPService(type: .humiditySensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .currentRelativeHumidity, value: .float(50),
                permissions: [.read, .notify], format: .float,
                minValue: 0, maxValue: 100, minStep: 1,
                unit: .percentage
            ),
        ])
    }

    public static func contactSensor(startIID: UInt64) -> HAPService {
        HAPService(type: .contactSensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .contactSensorState, value: .uint8(0),
                permissions: [.read, .notify], format: .uint8,
                minValue: 0, maxValue: 1
            ),
        ])
    }

    public static func leakSensor(startIID: UInt64) -> HAPService {
        HAPService(type: .leakSensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .leakDetected, value: .uint8(0),
                permissions: [.read, .notify], format: .uint8,
                minValue: 0, maxValue: 1
            ),
        ])
    }

    public static func smokeSensor(startIID: UInt64) -> HAPService {
        HAPService(type: .smokeSensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .smokeDetected, value: .uint8(0),
                permissions: [.read, .notify], format: .uint8,
                minValue: 0, maxValue: 1
            ),
        ])
    }

    public static func carbonMonoxideSensor(startIID: UInt64) -> HAPService {
        HAPService(type: .carbonMonoxideSensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .carbonMonoxideDetected, value: .uint8(0),
                permissions: [.read, .notify], format: .uint8,
                minValue: 0, maxValue: 1
            ),
        ])
    }

    public static func occupancySensor(startIID: UInt64) -> HAPService {
        HAPService(type: .occupancySensor, characteristics: [
            HAPCharacteristic(
                iid: startIID, type: .occupancyDetected, value: .uint8(0),
                permissions: [.read, .notify], format: .uint8,
                minValue: 0, maxValue: 1
            ),
        ])
    }
}

// MARK: - Media

extension HAPService {
    public static func speaker(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .mute, value: .bool(false),
            permissions: [.read, .write, .notify], format: .bool
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .volume, value: .uint8(50),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 100, minStep: 1,
            unit: .percentage
        ))

        return HAPService(type: .speaker, characteristics: chars)
    }
}
