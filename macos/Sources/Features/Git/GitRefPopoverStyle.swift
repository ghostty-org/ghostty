import AppKit
import SwiftUI

enum GitRefPopoverStyle {
    static let size = NSSize(width: 380, height: 380)
    static func pickerSize(branchCount: Int, worktreeCount: Int, tagCount: Int) -> NSSize {
        let rows = branchCount + worktreeCount + tagCount
        return NSSize(width: 340, height: min(520, max(220, 130 + CGFloat(rows) * 30)))
    }
    static func content<V: View>(_ view: V, colors: GitCollectionColors, size: NSSize = size) -> AnyView {
        AnyView(view.padding(.vertical, 10).frame(width: size.width, height: size.height)
            .background(Color(colors.background)).environment(\.gitCollectionColors, colors))
    }
}

final class GitScopeButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 10, y: rect.midY - 7, width: 14, height: 14)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 30, y: super.titleRect(forBounds: rect).minY,
               width: max(0, rect.width - 58), height: super.titleRect(forBounds: rect).height)
    }
}
