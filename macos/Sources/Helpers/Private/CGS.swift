import AppKit

// MARK: - CGS Private API Declarations

typealias CGSConnectionID = Int32
typealias CGSSpaceID = size_t

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: CGSConnectionID, _ spaceID: CGSSpaceID) -> CGSSpaceType

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(
    _ cid: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windowIDs: CFArray
) -> Unmanaged<CFArray>?

// MARK: - CGS Space

/// https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSSpace.h#L40
/// converted to Swift
struct CGSSpaceMask: OptionSet {
    let rawValue: UInt32

    static let includesCurrent = CGSSpaceMask(rawValue: 1 << 0)
    static let includesOthers = CGSSpaceMask(rawValue: 1 << 1)
    static let includesUser = CGSSpaceMask(rawValue: 1 << 2)

    static let includesVisible = CGSSpaceMask(rawValue: 1 << 16)

    static let currentSpace: CGSSpaceMask = [.includesUser, .includesCurrent]
    static let otherSpaces: CGSSpaceMask = [.includesOthers, .includesCurrent]
    static let allSpaces: CGSSpaceMask = [.includesUser, .includesOthers, .includesCurrent]
    static let allVisibleSpaces: CGSSpaceMask = [.includesVisible, .allSpaces]
}

/// Represents a unique identifier for a macOS Space (Desktop, Fullscreen, etc).
struct CGSSpace: Hashable, CustomStringConvertible {
    let rawValue: CGSSpaceID

    var description: String {
        "SpaceID(\(rawValue))"
    }

    /// Returns the currently active space.
    static func active() -> CGSSpace {
        let space = CGSGetActiveSpace(CGSMainConnectionID())
        return .init(rawValue: space)
    }

    /// List the spaces for the given window.
    static func list(for windowID: CGWindowID, mask: CGSSpaceMask = .allSpaces) -> [CGSSpace] {
        guard let spaces = CGSCopySpacesForWindows(
            CGSMainConnectionID(),
            mask,
            [windowID] as CFArray
        ) else { return [] }
        guard let spaceIDs = spaces.takeRetainedValue() as? [CGSSpaceID] else { return [] }
        return spaceIDs.map(CGSSpace.init)
    }
}

// MARK: - CGS Space Types

enum CGSSpaceType: UInt32 {
    case user = 0
    case system = 2
    case fullscreen = 4
}

extension CGSSpace {
    var type: CGSSpaceType {
        CGSSpaceGetType(CGSMainConnectionID(), rawValue)
    }

    var screen: NSScreen? {
        guard let displayUUID else { return nil }
        return NSScreen.screens.first { $0.displayUUID == displayUUID }
    }

    static func currentFullscreenScreen(frontmostApplicationProcessIdentifier: pid_t?) -> NSScreen? {
        guard let displayUUID = currentFullscreenDisplayUUID(
            frontmostApplicationProcessIdentifier: frontmostApplicationProcessIdentifier,
            managedDisplaySpaces: managedDisplaySpaces()
        ) else { return nil }

        return NSScreen.screens.first { $0.displayUUID == displayUUID }
    }

    private var displayUUID: UUID? {
        Self.displayUUID(for: self, managedDisplaySpaces: Self.managedDisplaySpaces())
    }

    static func displayUUID(for space: CGSSpace, managedDisplaySpaces: [[String: Any]]) -> UUID? {
        for displaySpaces in managedDisplaySpaces {
            guard
                let displayIdentifier = displaySpaces["Display Identifier"] as? String,
                let currentSpace = displaySpaces["Current Space"] as? [String: Any],
                let managedSpaceID = spaceID(from: currentSpace["ManagedSpaceID"]),
                managedSpaceID == space.rawValue
            else { continue }

            return UUID(uuidString: displayIdentifier)
        }

        return nil
    }

    static func currentFullscreenDisplayUUID(
        frontmostApplicationProcessIdentifier: pid_t?,
        managedDisplaySpaces: [[String: Any]]
    ) -> UUID? {
        var fullscreenDisplayUUIDs: [UUID] = []

        for displaySpaces in managedDisplaySpaces {
            guard
                let displayIdentifier = displaySpaces["Display Identifier"] as? String,
                let displayUUID = UUID(uuidString: displayIdentifier),
                let currentSpace = displaySpaces["Current Space"] as? [String: Any],
                spaceType(from: currentSpace["type"]) == .fullscreen
            else { continue }

            if let frontmostApplicationProcessIdentifier,
               processIdentifier(from: currentSpace["pid"]) == frontmostApplicationProcessIdentifier {
                return displayUUID
            }

            fullscreenDisplayUUIDs.append(displayUUID)
        }

        guard fullscreenDisplayUUIDs.count == 1 else { return nil }
        return fullscreenDisplayUUIDs[0]
    }

    private static func managedDisplaySpaces() -> [[String: Any]] {
        guard let spaces = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) else { return [] }
        return spaces.takeRetainedValue() as? [[String: Any]] ?? []
    }

    private static func spaceID(from value: Any?) -> CGSSpaceID? {
        if let value = value as? Int {
            guard value >= 0 else { return nil }
            return CGSSpaceID(value)
        }

        if let value = value as? UInt {
            return CGSSpaceID(value)
        }

        if let value = value as? NSNumber {
            return CGSSpaceID(value.uint64Value)
        }

        return nil
    }

    private static func spaceType(from value: Any?) -> CGSSpaceType? {
        if let value = value as? UInt32 {
            return CGSSpaceType(rawValue: value)
        }

        if let value = value as? Int {
            guard value >= 0 else { return nil }
            return CGSSpaceType(rawValue: UInt32(value))
        }

        if let value = value as? UInt {
            return CGSSpaceType(rawValue: UInt32(value))
        }

        if let value = value as? NSNumber {
            return CGSSpaceType(rawValue: value.uint32Value)
        }

        return nil
    }

    private static func processIdentifier(from value: Any?) -> pid_t? {
        if let value = value as? pid_t {
            return value
        }

        if let value = value as? Int {
            return pid_t(value)
        }

        if let value = value as? NSNumber {
            return pid_t(value.int32Value)
        }

        return nil
    }
}
