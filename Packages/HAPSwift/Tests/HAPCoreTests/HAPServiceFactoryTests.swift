// HAPServiceFactoryTests.swift
// Copyright 2026 Monagle Pty Ltd

import Testing
@testable import HAPCore

@Suite("HAPService Factory Tests")
struct HAPServiceFactoryTests {

    // MARK: - Lightbulb

    @Test("lightbulb with all features has 5 characteristics")
    func lightbulbFullFeatures() {
        let service = HAPService.lightbulb(
            startIID: 1,
            supportsBrightness: true,
            supportsColorTemperature: true,
            supportsColor: true
        )
        #expect(service.type == .lightbulb)
        #expect(service.characteristics.count == 5)
        #expect(service.characteristics[0].type == .on)
        #expect(service.characteristics[1].type == .brightness)
        #expect(service.characteristics[2].type == .hue)
        #expect(service.characteristics[3].type == .saturation)
        #expect(service.characteristics[4].type == .colorTemperature)
    }

    @Test("lightbulb on-only has 1 characteristic")
    func lightbulbOnOnly() {
        let service = HAPService.lightbulb(
            startIID: 1,
            supportsBrightness: false,
            supportsColorTemperature: false,
            supportsColor: false
        )
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .on)
    }

    @Test("lightbulb dimmable has 2 characteristics")
    func lightbulbDimmable() {
        let service = HAPService.lightbulb(startIID: 1)
        #expect(service.characteristics.count == 2)
        #expect(service.characteristics[0].type == .on)
        #expect(service.characteristics[1].type == .brightness)
    }

    @Test("lightbulb IIDs are sequential")
    func lightbulbIIDs() {
        let service = HAPService.lightbulb(
            startIID: 10,
            supportsBrightness: true,
            supportsColorTemperature: true,
            supportsColor: true
        )
        for (index, char) in service.characteristics.enumerated() {
            #expect(char.iid == UInt64(10 + index))
        }
    }

    @Test("lightbulb On is bool, read+write+notify")
    func lightbulbOnPermissions() {
        let service = HAPService.lightbulb(startIID: 1)
        let on = service.characteristics[0]
        #expect(on.format == .bool)
        #expect(on.isReadable)
        #expect(on.isWritable)
        #expect(on.supportsNotification)
    }

    // MARK: - Switch

    @Test("switch factory creates correct service")
    func switchFactory() {
        let service = HAPService.switch(startIID: 1)
        #expect(service.type == .switch)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .on)
        #expect(service.characteristics[0].isWritable)
    }

    // MARK: - Outlet

    @Test("outlet factory creates On and OutletInUse")
    func outletFactory() {
        let service = HAPService.outlet(startIID: 5)
        #expect(service.type == .outlet)
        #expect(service.characteristics.count == 2)
        #expect(service.characteristics[0].type == .on)
        #expect(service.characteristics[0].isWritable)
        #expect(service.characteristics[1].type == .outletInUse)
        #expect(!service.characteristics[1].isWritable)
        #expect(service.characteristics[0].iid == 5)
        #expect(service.characteristics[1].iid == 6)
    }

    // MARK: - Fan v2

    @Test("fanV2 factory creates 4 characteristics")
    func fanV2Factory() {
        let service = HAPService.fanV2(startIID: 1)
        #expect(service.type == .fanV2)
        #expect(service.characteristics.count == 4)
        #expect(service.characteristics[0].type == .active)
        #expect(service.characteristics[1].type == .rotationSpeed)
        #expect(service.characteristics[2].type == .rotationDirection)
        #expect(service.characteristics[3].type == .swingMode)
    }

    // MARK: - Door Lock

    @Test("doorLock factory creates current and target state")
    func doorLockFactory() {
        let service = HAPService.doorLock(startIID: 1)
        #expect(service.type == .doorLock)
        #expect(service.characteristics.count == 2)
        #expect(service.characteristics[0].type == .lockCurrentState)
        #expect(!service.characteristics[0].isWritable)
        #expect(service.characteristics[1].type == .lockTargetState)
        #expect(service.characteristics[1].isWritable)
    }

    // MARK: - Window Covering

    @Test("windowCovering factory creates 3 characteristics")
    func windowCoveringFactory() {
        let service = HAPService.windowCovering(startIID: 1)
        #expect(service.type == .windowCovering)
        #expect(service.characteristics.count == 3)
        #expect(service.characteristics[0].type == .currentPosition)
        #expect(!service.characteristics[0].isWritable)
        #expect(service.characteristics[1].type == .targetPosition)
        #expect(service.characteristics[1].isWritable)
        #expect(service.characteristics[2].type == .positionState)
        #expect(!service.characteristics[2].isWritable)
    }

    // MARK: - Thermostat

    @Test("thermostat factory creates 5 characteristics")
    func thermostatFactory() {
        let service = HAPService.thermostat(startIID: 1)
        #expect(service.type == .thermostat)
        #expect(service.characteristics.count == 5)
        #expect(service.characteristics[0].type == .currentTemperature)
        #expect(!service.characteristics[0].isWritable)
        #expect(service.characteristics[1].type == .targetTemperature)
        #expect(service.characteristics[1].isWritable)
        #expect(service.characteristics[2].type == .currentHeatingCoolingState)
        #expect(!service.characteristics[2].isWritable)
        #expect(service.characteristics[3].type == .targetHeatingCoolingState)
        #expect(service.characteristics[3].isWritable)
        #expect(service.characteristics[4].type == .currentRelativeHumidity)
    }

    // MARK: - Motion Sensor

    @Test("motionSensor factory creates single characteristic")
    func motionSensorFactory() {
        let service = HAPService.motionSensor(startIID: 1)
        #expect(service.type == .motionSensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .motionDetected)
        #expect(service.characteristics[0].format == .bool)
        #expect(!service.characteristics[0].isWritable)
        #expect(service.characteristics[0].supportsNotification)
    }

    // MARK: - Temperature Sensor

    @Test("temperatureSensor factory creates correct service")
    func temperatureSensorFactory() {
        let service = HAPService.temperatureSensor(startIID: 1)
        #expect(service.type == .temperatureSensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .currentTemperature)
        #expect(service.characteristics[0].format == .float)
    }

    // MARK: - Humidity Sensor

    @Test("humiditySensor factory creates correct service")
    func humiditySensorFactory() {
        let service = HAPService.humiditySensor(startIID: 1)
        #expect(service.type == .humiditySensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .currentRelativeHumidity)
    }

    // MARK: - Contact Sensor

    @Test("contactSensor factory creates correct service")
    func contactSensorFactory() {
        let service = HAPService.contactSensor(startIID: 1)
        #expect(service.type == .contactSensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .contactSensorState)
        #expect(service.characteristics[0].format == .uint8)
    }

    // MARK: - Leak Sensor

    @Test("leakSensor factory creates correct service")
    func leakSensorFactory() {
        let service = HAPService.leakSensor(startIID: 1)
        #expect(service.type == .leakSensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .leakDetected)
    }

    // MARK: - Smoke Sensor

    @Test("smokeSensor factory creates correct service")
    func smokeSensorFactory() {
        let service = HAPService.smokeSensor(startIID: 1)
        #expect(service.type == .smokeSensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .smokeDetected)
    }

    // MARK: - Carbon Monoxide Sensor

    @Test("carbonMonoxideSensor factory creates correct service")
    func carbonMonoxideSensorFactory() {
        let service = HAPService.carbonMonoxideSensor(startIID: 1)
        #expect(service.type == .carbonMonoxideSensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .carbonMonoxideDetected)
    }

    // MARK: - Occupancy Sensor

    @Test("occupancySensor factory creates correct service")
    func occupancySensorFactory() {
        let service = HAPService.occupancySensor(startIID: 1)
        #expect(service.type == .occupancySensor)
        #expect(service.characteristics.count == 1)
        #expect(service.characteristics[0].type == .occupancyDetected)
    }

    // MARK: - Speaker

    @Test("speaker factory creates mute and volume")
    func speakerFactory() {
        let service = HAPService.speaker(startIID: 1)
        #expect(service.type == .speaker)
        #expect(service.characteristics.count == 2)
        #expect(service.characteristics[0].type == .mute)
        #expect(service.characteristics[0].isWritable)
        #expect(service.characteristics[1].type == .volume)
        #expect(service.characteristics[1].isWritable)
        #expect(service.characteristics[0].iid == 1)
        #expect(service.characteristics[1].iid == 2)
    }
}
