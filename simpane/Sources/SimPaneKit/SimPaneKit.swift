//  SimPaneKit — a live, interactive iOS Simulator mirror in an NSView.
//
//  The device runs headlessly under `simctl`; this library renders its
//  framebuffer and forwards input, with no Simulator.app involved.
//
//  Nothing here is linked against a private framework. If Xcode is missing, or
//  the private API has moved, `SimulatorSession.support()` reports
//  `.unsupported(reason:)` and every other entry point fails with that reason
//  rather than crashing. See Private/PrivateSim.swift.

import Foundation

/// Whether this machine can host a simulator pane, and why not when it cannot.
///
/// The reason string is meant to be shown to a user: it names the missing piece
/// (no Xcode, framework absent, class renamed) rather than a status code.
public enum SimPaneSupport: Equatable {
    case supported
    case unsupported(reason: String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var reason: String? {
        if case .unsupported(let r) = self { return r }
        return nil
    }
}

/// Every failure this library reports. One type, one human-readable message:
/// the underlying failures come from private frameworks and shell tools that
/// share no error domain, so a code would be inventing structure that is not
/// there.
public struct SimPaneError: LocalizedError, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A hardware button on the guest device.
public enum HardwareButton: String, CaseIterable, Sendable {
    case home
    case lock
    case siri
    case side
    case applePay
}
