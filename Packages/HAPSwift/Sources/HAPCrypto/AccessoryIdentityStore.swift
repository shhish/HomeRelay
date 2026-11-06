// AccessoryIdentityStore.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

public struct AccessoryIdentity: Sendable, Codable {
    public let deviceID: String
    public let privateKey: Data
    public let setupCode: String
    public let setupID: String
    public var identity: HAPIdentity { get throws { try HAPIdentity(privateKeyData: privateKey) } }

    public init(setupCode: String) throws {
        guard Self.validSetupCode(setupCode) else { throw HAPCryptoError.invalidKeyData }
        self.setupCode = setupCode
        self.privateKey = HAPIdentity().privateKeyData
        self.deviceID = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
        self.setupID = String((0..<4).map { _ in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! })
    }

    public static func generateSetupCode() -> String {
        while true {
            let code = String(format: "%03d-%02d-%03d", Int.random(in: 0...999), Int.random(in: 0...99), Int.random(in: 0...999))
            if validSetupCode(code) { return code }
        }
    }

    private static func validSetupCode(_ code: String) -> Bool {
        let digits = code.replacingOccurrences(of: "-", with: "")
        return code.count == 10 && code[code.index(code.startIndex, offsetBy: 3)] == "-"
            && code[code.index(code.startIndex, offsetBy: 6)] == "-"
            && digits.count == 8 && digits.allSatisfy({ $0.isASCII && $0.isNumber })
            && Set(digits).count > 1 && digits != "12345678" && digits != "87654321"
    }

    public func validate() throws {
        guard Self.validSetupCode(setupCode), privateKey.count == 32,
              deviceID.split(separator: ":").count == 6,
              deviceID.split(separator: ":").allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }),
              setupID.count == 4 && setupID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw HAPCryptoError.invalidKeyData
        }
        _ = try identity
    }
}

public protocol AccessoryIdentityStore: Sendable {
    func loadOrCreate(setupCode: String) async throws -> AccessoryIdentity
}

public actor FileAccessoryIdentityStore: AccessoryIdentityStore {
    private let url: URL
    private let allowsCreation: Bool
    public init(url: URL, allowsCreation: Bool = true) {
        self.url = url
        self.allowsCreation = allowsCreation
    }

    public func loadOrCreate(setupCode: String) throws -> AccessoryIdentity {
        if let data = try AtomicFile.read(url) {
            let saved = try JSONDecoder().decode(AccessoryIdentity.self, from: data)
            try saved.validate()
            guard saved.setupCode == setupCode else { throw HAPCryptoError.invalidKeyData }
            return saved
        }
        guard allowsCreation else { throw HAPCryptoError.invalidKeyData }
        let identity = try AccessoryIdentity(setupCode: setupCode)
        try AtomicFile.write(JSONEncoder().encode(identity), to: url)
        return identity
    }
}
