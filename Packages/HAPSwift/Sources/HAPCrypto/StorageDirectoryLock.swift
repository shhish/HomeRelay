// StorageDirectoryLock.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Hold for the lifetime of a bridge's file stores. Prevents two accessory
/// processes from independently overwriting the same identity/pairing/layout files.
/// The descriptor is immutable; the OS releases the lock even after a process crash.
public final class StorageDirectoryLock: @unchecked Sendable {
    private let descriptor: Int32

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
