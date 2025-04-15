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
}
