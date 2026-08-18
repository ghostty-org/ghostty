//  The public description of a simulator device.
//
//  Carries no CoreSimulator object: a caller holding one of these holds no
//  private API, so this type can cross into Ghostty's UI freely.

import Foundation

public struct SimDeviceInfo: Equatable, Identifiable, Sendable {

    public enum State: String, Equatable, Sendable {
        case creating
        case shutdown
        case booting
        case booted
        case shuttingDown
        case unknown

        /// `simctl list -j` spells these out; CoreSimulator numbers them. Both
        /// spellings reach this type, so both are parsed here rather than at the
        /// call sites.
        public init(simctlName: String) {
            switch simctlName {
            case "Creating": self = .creating
            case "Shutdown": self = .shutdown
            case "Booting": self = .booting
            case "Booted": self = .booted
            case "Shutting Down": self = .shuttingDown
            default: self = .unknown
            }
        }

        init(coreSimulatorValue: Int) {
            switch coreSimulatorValue {
            case 0: self = .creating
            case 1: self = .shutdown
            case 2: self = .booting
            case 3: self = .booted
            case 4: self = .shuttingDown
            default: self = .unknown
            }
        }

        public var label: String {
            switch self {
            case .creating: return "Creating"
            case .shutdown: return "Shutdown"
            case .booting: return "Booting"
            case .booted: return "Booted"
            case .shuttingDown: return "Shutting Down"
            case .unknown: return "Unknown"
            }
        }
    }

    public let udid: String
    public let name: String
    /// Runtime identifier as simctl reports it, e.g.
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-3`.
    public let runtimeIdentifier: String
    public let state: State

    public var id: String { udid }
    public var isBooted: Bool { state == .booted }

    /// The runtime with Apple's reverse-DNS prefix removed and dashes turned back
    /// into dots, e.g. `iOS 26.3`. For display only.
    public var runtime: String {
        let bare = runtimeIdentifier
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        guard let dash = bare.firstIndex(of: "-") else { return bare }
        let platform = String(bare[bare.startIndex..<dash])
        let version = bare[bare.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        return "\(platform) \(version)"
    }

    public init(udid: String, name: String, runtimeIdentifier: String, state: State) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.state = state
    }
}
