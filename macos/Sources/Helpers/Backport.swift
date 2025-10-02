import SwiftUI

// All backport view/scene modifiers go as an extension on this. We use this
// so we can easily track and centralize all backports.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Backport where Content: Scene {
    // None currently
}

extension Backport where Content: View {
    func pointerVisibility(_ v: BackportVisibility) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerVisibility(v.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerStyle(style?.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    @MainActor @preconcurrency func backgroundExtensionEffect(isEnabled: Bool = true) -> some View {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            return content.backgroundExtensionEffect(isEnabled: isEnabled)
        } else {
            return content
        }
    }

    nonisolated func scrollEdgeEffectStyle(_ style: BackportScrollEdgeEffectStyle?, for edge: Edge.Set) -> some View {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            return content.scrollEdgeEffectStyle(style?.official, for: edge)
        } else {
            return content
        }
    }
}

enum BackportVisibility {
    case automatic
    case visible
    case hidden

    @available(macOS 15, *)
    var official: Visibility {
        switch self {
        case .automatic: return .automatic
        case .visible: return .visible
        case .hidden: return .hidden
        }
    }
}

enum BackportScrollEdgeEffectStyle: Hashable, Sendable {
    case automatic, hard, soft

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
    var official: ScrollEdgeEffectStyle {
        switch self {
        case .automatic: return .automatic
        case .hard: return .hard
        case .soft: return .soft
        }
    }
}
enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    #if canImport(AppKit)
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .default: return .default
        case .grabIdle: return .grabIdle
        case .grabActive: return .grabActive
        case .horizontalText: return .horizontalText
        case .verticalText: return .verticalText
        case .link: return .link
        case .resizeLeft: return .frameResize(position: .trailing, directions: [.inward])
        case .resizeRight: return .frameResize(position: .leading, directions: [.inward])
        case .resizeUp: return .frameResize(position: .bottom, directions: [.inward])
        case .resizeDown: return .frameResize(position: .top, directions: [.inward])
        case .resizeUpDown: return .frameResize(position: .top)
        case .resizeLeftRight: return .frameResize(position: .trailing)
        }
    }
    #endif
}
