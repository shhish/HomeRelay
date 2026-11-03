import Foundation

// Wire models for the HomeRelay API. Field names are the public contract;
// see docs/API.md before renaming anything.

public struct HomeSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var rooms: Int
    public var accessories: Int
    public var scenes: Int

    public init(id: String, name: String, rooms: Int, accessories: Int, scenes: Int) {
        self.id = id
        self.name = name
        self.rooms = rooms
        self.accessories = accessories
        self.scenes = scenes
    }
}

public struct RoomDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var home: String
    public var accessoryIds: [String]

    public init(id: String, name: String, home: String, accessoryIds: [String]) {
        self.id = id
        self.name = name
        self.home = home
        self.accessoryIds = accessoryIds
    }
}

public struct CharacteristicDTO: Codable, Sendable, Equatable {
    public var id: String
    /// Stable camelCase name, e.g. `on`, `brightness`, `currentTemperature`.
    public var type: String
    /// Apple's human-readable label, e.g. "Power State".
    public var label: String
    public var value: JSONValue?
    public var format: String?
    public var unit: String?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var validValues: [Int]?
    public var readable: Bool
    public var writable: Bool
    public var notifies: Bool

    public init(
        id: String, type: String, label: String, value: JSONValue?, format: String?, unit: String?,
        min: Double?, max: Double?, step: Double?, validValues: [Int]?,
        readable: Bool, writable: Bool, notifies: Bool
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.value = value
        self.format = format
        self.unit = unit
        self.min = min
        self.max = max
        self.step = step
        self.validValues = validValues
        self.readable = readable
        self.writable = writable
        self.notifies = notifies
    }

    public var spec: ValueSpec {
        ValueSpec(format: format, min: min, max: max, step: step, validValues: validValues)
    }
}

public struct ServiceDTO: Codable, Sendable, Equatable {
    public var id: String
    /// Stable camelCase name, e.g. `lightbulb`, `fan`, `accessoryInformation`.
    public var type: String
    public var name: String
    public var primary: Bool
    public var characteristics: [CharacteristicDTO]

    public init(id: String, type: String, name: String, primary: Bool, characteristics: [CharacteristicDTO]) {
        self.id = id
        self.type = type
        self.name = name
        self.primary = primary
        self.characteristics = characteristics
    }

    public var isInformation: Bool { type == "accessoryInformation" }
}

public struct AccessoryDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var home: String
    public var room: String?
    public var category: String
    public var reachable: Bool
    public var bridged: Bool
    public var manufacturer: String?
    public var model: String?
    /// Flattened `type -> value` view of the non-information services, primary
    /// service first. This is what most clients want to show.
    public var state: [String: JSONValue]
    public var services: [ServiceDTO]

    public init(
        id: String, name: String, home: String, room: String?, category: String,
        reachable: Bool, bridged: Bool, manufacturer: String?, model: String?, services: [ServiceDTO]
    ) {
        self.id = id
        self.name = name
        self.home = home
        self.room = room
        self.category = category
        self.reachable = reachable
        self.bridged = bridged
        self.manufacturer = manufacturer
        self.model = model
        self.services = services
        self.state = AccessoryDTO.summarize(services)
    }

    /// Characteristics that clients can control by friendly name, primary
    /// service first and information service excluded.
    public var controllable: [CharacteristicDTO] {
        orderedServices.filter { !$0.isInformation }.flatMap(\.characteristics)
    }

    private var orderedServices: [ServiceDTO] {
        services.filter(\.primary) + services.filter { !$0.primary }
    }

    /// Device-information and bookkeeping values that clutter `state`.
    static let stateSkips: Set<String> = [
        "name", "identify", "configuredName", "buttonEvent", "manufacturer", "model", "serialNumber",
        "firmwareRevision", "hardwareRevision", "softwareRevision", "labelIndex", "labelNamespace",
    ]

    /// Vendor-defined (non-Apple) types are named `custom.<uuid prefix>`.
    public static func isCustom(_ type: String) -> Bool { type.hasPrefix("custom.") }

    /// The same accessory without per-service detail, for small responses.
    public var compact: AccessoryDTO {
        var copy = self
        copy.services = []
        return copy
    }

    static func summarize(_ services: [ServiceDTO]) -> [String: JSONValue] {
        var state: [String: JSONValue] = [:]
        let ordered = services.filter(\.primary) + services.filter { !$0.primary }
        for service in ordered where !service.isInformation {
            for c in service.characteristics where state[c.type] == nil && !stateSkips.contains(c.type) && !isCustom(c.type) {
                if let v = c.value { state[c.type] = v }
            }
        }
        return state
    }
}

public enum CategoryInference {
    /// Apple reports most bridged accessories (Hue, Homebridge) as `other`, so
    /// fall back to what the accessory's services say it is, primary first.
    public static func infer(reported: String, serviceTypes: [String]) -> String {
        guard reported == "other" else { return reported }
        for type in serviceTypes {
            if let category = byService[type] { return category }
        }
        return reported
    }

    private static let byService: [String: String] = [
        "lightbulb": "lightbulb", "switch": "switch", "outlet": "outlet", "fan": "fan",
        "thermostat": "thermostat", "heaterCooler": "thermostat", "lock": "doorLock",
        "garageDoor": "garageDoor", "windowCovering": "windowCovering", "window": "window", "door": "door",
        "airPurifier": "airPurifier", "humidifier": "humidifier", "television": "television", "speaker": "speaker",
        "button": "button", "doorbell": "doorbell", "securitySystem": "securitySystem", "valve": "valve",
        "motionSensor": "sensor", "occupancySensor": "sensor", "contactSensor": "sensor",
        "temperatureSensor": "sensor", "humiditySensor": "sensor", "lightSensor": "sensor",
        "airQualitySensor": "sensor", "smokeSensor": "sensor", "leakSensor": "sensor",
    ]
}

public struct SceneDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var home: String
    /// Apple's built-in scene kind (`wakeUp`, `sleep`, `homeArrival`, `homeDeparture`) or `user`.
    public var kind: String

    public init(id: String, name: String, home: String, kind: String) {
        self.id = id
        self.name = name
        self.home = home
        self.kind = kind
    }
}

public struct HomeDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var rooms: [RoomDTO]
    public var accessories: [AccessoryDTO]
    public var scenes: [SceneDTO]

    public init(id: String, name: String, rooms: [RoomDTO], accessories: [AccessoryDTO], scenes: [SceneDTO]) {
        self.id = id
        self.name = name
        self.rooms = rooms
        self.accessories = accessories
        self.scenes = scenes
    }
}

/// A change pushed to `/api/v1/events` subscribers.
public struct HomeEvent: Codable, Sendable, Equatable {
    /// `characteristic`, `reachability` or `homes`.
    public var type: String
    public var home: String?
    public var accessoryId: String?
    public var accessory: String?
    public var room: String?
    public var serviceId: String?
    public var characteristicId: String?
    public var characteristic: String?
    public var value: JSONValue?
    public var reachable: Bool?
    public var ts: String

    public init(
        type: String, home: String? = nil, accessoryId: String? = nil, accessory: String? = nil,
        room: String? = nil, serviceId: String? = nil, characteristicId: String? = nil,
        characteristic: String? = nil, value: JSONValue? = nil, reachable: Bool? = nil, ts: String = HomeEvent.now()
    ) {
        self.type = type
        self.home = home
        self.accessoryId = accessoryId
        self.accessory = accessory
        self.room = room
        self.serviceId = serviceId
        self.characteristicId = characteristicId
        self.characteristic = characteristic
        self.value = value
        self.reachable = reachable
        self.ts = ts
    }

    public static func now() -> String {
        Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}

public struct BackendStatus: Codable, Sendable, Equatable {
    /// `starting`, `ready`, `notAuthorized`, `noHomes`.
    public var state: String
    public var detail: String?

    public init(state: String, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    public var isReady: Bool { state == "ready" }
}
