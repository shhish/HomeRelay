// HAPStatus.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPStatus: Int, Sendable {
    case success = 0
    case insufficientPrivileges = -70401
    case communicationFailure = -70402
    case busy = -70403
    case readOnly = -70404
    case writeOnly = -70405
    case notificationNotSupported = -70406
    case outOfResources = -70407
    case operationTimedOut = -70408
    case resourceDoesNotExist = -70409
    case invalidValueInRequest = -70410
    case insufficientAuthorization = -70411
    case notAllowedInCurrentState = -70412
}
