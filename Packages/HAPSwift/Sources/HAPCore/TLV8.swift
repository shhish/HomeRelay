// TLV8.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

public enum TLV8 {

    public typealias Item = (type: UInt8, value: Data)

    // MARK: - Encode

    public static func encode(_ items: [Item]) -> Data {
        var result = Data()
        for item in items {
            let value = item.value
            if value.isEmpty {
                result.append(item.type)
                result.append(0)
                continue
            }
            var offset = 0
            while offset < value.count {
                let chunkSize = min(255, value.count - offset)
                result.append(item.type)
                result.append(UInt8(chunkSize))
                result.append(value[value.startIndex + offset ..< value.startIndex + offset + chunkSize])
                offset += chunkSize
            }
        }
        return result
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> [Item] {
        var items: [Item] = []
        var offset = data.startIndex
        var sawSeparator = false

        while offset < data.endIndex {
            guard offset + 1 < data.endIndex else {
                throw HAPError.invalidTLV
            }
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2

            guard offset + length <= data.endIndex else {
                throw HAPError.invalidTLV
            }
            let value = data[offset ..< offset + length]
            offset += length

            // Separator: type 0xFF with length 0
            if type == TLV8Type.separator.rawValue && length == 0 {
                sawSeparator = true
                continue
            }

            // Merge fragmented values (consecutive entries with same type, no separator between)
            if !sawSeparator, let last = items.last, last.type == type {
                items[items.count - 1].value.append(contentsOf: value)
            } else {
                items.append((type: type, value: Data(value)))
            }
            sawSeparator = false
        }

        return items
    }
}
