@_exported import CGhosttyKit

// MARK: - macOS

/// for symbols like `_TISCopyCurrentKeyboardLayoutInputSource`
#if canImport(Carbon)
@_exported import Carbon
#endif

/// for symbols like `_CVDisplayLinkStart`
#if canImport(AppKit)
@_exported import AppKit
#endif

// MARK: - iOS

#if canImport(UIKit)
@_exported import UIKit
#endif
