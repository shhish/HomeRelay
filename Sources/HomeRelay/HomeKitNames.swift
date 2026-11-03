import HomeKit
import HomeRelayCore

/// Stable API names for HomeKit types. Anything not listed falls back to a
/// camelCased version of Apple's label, so new device kinds still get a name.
enum HomeKitNames {
    static func characteristic(_ c: HMCharacteristic) -> String {
        characteristics[c.characteristicType] ?? fallback(type: c.characteristicType, label: c.localizedDescription)
    }

    static func service(_ s: HMService) -> String {
        services[s.serviceType] ?? fallback(type: s.serviceType, label: s.localizedDescription)
    }

    /// Apple-defined types share this UUID suffix; anything else is vendor-defined.
    private static let appleSuffix = "-0000-1000-8000-0026BB765291"

    /// Vendor types (Hue, Ecobee, Eve...) and Apple types this SDK has no label
    /// for are all called "Custom", so they get `custom.<first 8 hex digits>`.
    private static func fallback(type: String, label: String) -> String {
        let name = Naming.camelCase(label)
        if type.uppercased().hasSuffix(appleSuffix) && name != "custom" { return name }
        return "custom." + type.prefix(8).lowercased()
    }

    static func category(_ c: HMAccessoryCategory) -> String {
        categories[c.categoryType] ?? Naming.camelCase(c.localizedDescription)
    }

    static func sceneKind(_ type: String) -> String {
        switch type {
        case HMActionSetTypeWakeUp: "wakeUp"
        case HMActionSetTypeSleep: "sleep"
        case HMActionSetTypeHomeArrival: "homeArrival"
        case HMActionSetTypeHomeDeparture: "homeDeparture"
        case HMActionSetTypeTriggerOwned: "triggerOwned"
        default: "user"
        }
    }

    private static let characteristics: [String: String] = [
        HMCharacteristicTypePowerState: "on",
        HMCharacteristicTypeActive: "active",
        HMCharacteristicTypeBrightness: "brightness",
        HMCharacteristicTypeHue: "hue",
        HMCharacteristicTypeSaturation: "saturation",
        HMCharacteristicTypeColorTemperature: "colorTemperature",
        HMCharacteristicTypeCurrentTemperature: "currentTemperature",
        HMCharacteristicTypeTargetTemperature: "targetTemperature",
        HMCharacteristicTypeCurrentHeatingCooling: "currentHeatingCooling",
        HMCharacteristicTypeTargetHeatingCooling: "targetHeatingCooling",
        HMCharacteristicTypeTemperatureUnits: "temperatureUnits",
        HMCharacteristicTypeCurrentRelativeHumidity: "humidity",
        HMCharacteristicTypeTargetRelativeHumidity: "targetHumidity",
        HMCharacteristicTypeCurrentLockMechanismState: "lockState",
        HMCharacteristicTypeTargetLockMechanismState: "lockTarget",
        HMCharacteristicTypeRotationSpeed: "rotationSpeed",
        HMCharacteristicTypeRotationDirection: "rotationDirection",
        HMCharacteristicTypeCurrentFanState: "fanState",
        HMCharacteristicTypeTargetFanState: "fanMode",
        HMCharacteristicTypeSwingMode: "swing",
        HMCharacteristicTypeLockPhysicalControls: "childLock",
        HMCharacteristicTypeMotionDetected: "motion",
        HMCharacteristicTypeOccupancyDetected: "occupancy",
        HMCharacteristicTypeContactState: "contact",
        HMCharacteristicTypeStatusActive: "statusActive",
        HMCharacteristicTypeStatusFault: "fault",
        HMCharacteristicTypeStatusLowBattery: "lowBattery",
        HMCharacteristicTypeBatteryLevel: "batteryLevel",
        HMCharacteristicTypeChargingState: "charging",
        HMCharacteristicTypeCurrentPosition: "position",
        HMCharacteristicTypeTargetPosition: "targetPosition",
        HMCharacteristicTypePositionState: "positionState",
        HMCharacteristicTypeCurrentDoorState: "doorState",
        HMCharacteristicTypeTargetDoorState: "doorTarget",
        HMCharacteristicTypeObstructionDetected: "obstruction",
        HMCharacteristicTypeInputEvent: "buttonEvent",
        HMCharacteristicTypeOutletInUse: "inUse",
        HMCharacteristicTypeCurrentLightLevel: "lightLevel",
        HMCharacteristicTypeAirQuality: "airQuality",
        HMCharacteristicTypeCurrentAirPurifierState: "purifierState",
        HMCharacteristicTypeTargetAirPurifierState: "purifierMode",
        HMCharacteristicTypeSmokeDetected: "smoke",
        HMCharacteristicTypeVolume: "volume",
        HMCharacteristicTypeMute: "mute",
        HMCharacteristicTypeName: "name",
        HMCharacteristicTypeConfiguredName: "configuredName",
        HMCharacteristicTypeIdentify: "identify",
    ]

    private static let services: [String: String] = [
        HMServiceTypeAccessoryInformation: "accessoryInformation",
        HMServiceTypeLightbulb: "lightbulb",
        HMServiceTypeSwitch: "switch",
        HMServiceTypeOutlet: "outlet",
        HMServiceTypeFan: "fan",
        HMServiceTypeVentilationFan: "fan",
        HMServiceTypeThermostat: "thermostat",
        HMServiceTypeHeaterCooler: "heaterCooler",
        HMServiceTypeLockMechanism: "lock",
        HMServiceTypeGarageDoorOpener: "garageDoor",
        HMServiceTypeWindowCovering: "windowCovering",
        HMServiceTypeWindow: "window",
        HMServiceTypeDoor: "door",
        HMServiceTypeMotionSensor: "motionSensor",
        HMServiceTypeOccupancySensor: "occupancySensor",
        HMServiceTypeContactSensor: "contactSensor",
        HMServiceTypeTemperatureSensor: "temperatureSensor",
        HMServiceTypeHumiditySensor: "humiditySensor",
        HMServiceTypeLightSensor: "lightSensor",
        HMServiceTypeAirPurifier: "airPurifier",
        HMServiceTypeAirQualitySensor: "airQualitySensor",
        HMServiceTypeHumidifierDehumidifier: "humidifier",
        HMServiceTypeSmokeSensor: "smokeSensor",
        HMServiceTypeLeakSensor: "leakSensor",
        HMServiceTypeBattery: "battery",
        HMServiceTypeStatelessProgrammableSwitch: "button",
        HMServiceTypeValve: "valve",
        HMServiceTypeSecuritySystem: "securitySystem",
        HMServiceTypeDoorbell: "doorbell",
        HMServiceTypeTelevision: "television",
        HMServiceTypeSpeaker: "speaker",
    ]

    private static let categories: [String: String] = [
        HMAccessoryCategoryTypeLightbulb: "lightbulb",
        HMAccessoryCategoryTypeOutlet: "outlet",
        HMAccessoryCategoryTypeSwitch: "switch",
        HMAccessoryCategoryTypeFan: "fan",
        HMAccessoryCategoryTypeThermostat: "thermostat",
        HMAccessoryCategoryTypeDoorLock: "doorLock",
        HMAccessoryCategoryTypeDoor: "door",
        HMAccessoryCategoryTypeWindow: "window",
        HMAccessoryCategoryTypeWindowCovering: "windowCovering",
        HMAccessoryCategoryTypeGarageDoorOpener: "garageDoor",
        HMAccessoryCategoryTypeSensor: "sensor",
        HMAccessoryCategoryTypeSecuritySystem: "securitySystem",
        HMAccessoryCategoryTypeBridge: "bridge",
        HMAccessoryCategoryTypeIPCamera: "camera",
        HMAccessoryCategoryTypeVideoDoorbell: "doorbell",
        HMAccessoryCategoryTypeProgrammableSwitch: "button",
        HMAccessoryCategoryTypeRangeExtender: "rangeExtender",
        HMAccessoryCategoryTypeAirPurifier: "airPurifier",
        HMAccessoryCategoryTypeAirHeater: "heater",
        HMAccessoryCategoryTypeAirConditioner: "airConditioner",
        HMAccessoryCategoryTypeAirHumidifier: "humidifier",
        HMAccessoryCategoryTypeAirDehumidifier: "dehumidifier",
        HMAccessoryCategoryTypeSprinkler: "sprinkler",
        HMAccessoryCategoryTypeFaucet: "faucet",
        HMAccessoryCategoryTypeShowerHead: "showerHead",
        HMAccessoryCategoryTypeOther: "other",
    ]
}
