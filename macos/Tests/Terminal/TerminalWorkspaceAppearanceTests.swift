import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceAppearanceTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    @Test func rowActionsAlignAtTheTrailingEdgeAndHoverDoesNotSelect() throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        _ = fixture.store.create(name: "Short", symbol: "briefcase", color: "blue")
        _ = fixture.store.create(name: String(repeating: "Long title ", count: 3), symbol: "house", color: "mint")
        let picker = TerminalWorkspacePickerController(model: fixture.model)
        let window = NSWindow(contentRect: .init(origin: .zero, size: picker.fittingSize(proposedWidth: nil)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        defer { window.contentViewController = nil; window.close() }
        picker.view.layoutSubtreeIfNeeded()
        let table = try #require(find(NSTableView.self, in: picker.view).first)
        for index in 0..<table.numberOfRows {
            let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true))
            cell.layoutSubtreeIfNeeded()
            let buttons = find(NSButton.self, in: cell)
            let delete = try #require(buttons.first { $0.accessibilityIdentifier().hasPrefix("workspace.delete.") })
            let edit = try #require(buttons.first { $0.accessibilityIdentifier().hasPrefix("workspace.edit.") })
            #expect(abs(cell.bounds.maxX - delete.convert(delete.bounds, to: cell).maxX - 6) < 1)
            #expect(abs(edit.convert(edit.bounds, to: cell).maxX + 4 - delete.convert(delete.bounds, to: cell).minX) < 1)
            #expect(delete.title.isEmpty && edit.title.isEmpty)
            let row = try #require(table.rowView(atRow: index, makeIfNecessary: true) as? TerminalWorkspaceSelectionRow)
            let selected = fixture.model.selectedID
            row.mouseEntered(with: NSEvent())
            #expect(row.isHovered)
            #expect(fixture.model.selectedID == selected)
            row.mouseExited(with: NSEvent())
            #expect(!row.isHovered)
        }
        let move = try #require(find(NativeActionControl.self, in: picker.view).first {
            $0.accessibilityIdentifier() == "workspace.move"
        })
        #expect(move.controlStyle == .plain)
    }

    @Test func editorActionsStayAtBottomAndHeaderHasNoDefaultTitleOrReservedDotSpace() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let trigger = TerminalWorkspaceHeaderButton()
        func configure(_ attention: Bool) {
            trigger.configure(.init(name: "Work", symbol: "house", tint: .systemBlue,
                                    needsAttention: attention, isPresented: false, shortcut: ""),
                              controller: fixture.controller, activate: {})
        }
        configure(false)
        let normalWidth = trigger.fittingSize(proposedWidth: nil).width
        configure(true)
        #expect(trigger.fittingSize(proposedWidth: nil).width == normalWidth + 12)
        configure(false)
        #expect(trigger.fittingSize(proposedWidth: 80).width == 80)
        #expect(normalWidth < 100)

        let picker = TerminalWorkspacePickerController(model: fixture.model)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        defer { window.contentViewController = nil; window.close() }
        for editing in [false, true] {
            if editing { fixture.model.beginEdit(fixture.controller.workspaceID) } else { fixture.model.beginCreate() }
            try await Task.sleep(for: .milliseconds(50))
            window.setContentSize(picker.fittingSize(proposedWidth: nil))
            picker.view.layoutSubtreeIfNeeded()
            let buttons = find(NSButton.self, in: picker.view)
            let back = try #require(buttons.first { $0.accessibilityIdentifier() == "workspace.back" })
            #expect(back.title.isEmpty)
            #expect(back.bounds.width == 28)
            let save = try #require(buttons.first { $0.accessibilityIdentifier() == "workspace.save" })
            let rect = save.convert(save.bounds, to: picker.view)
            #expect(abs(rect.minY - 8) < 2)
            #expect(abs(rect.maxX - (picker.view.bounds.maxX - 10)) < 2)
            #expect(find(OMGNativeTextField.self, in: picker.view).count == 1)
            let surface = try #require(picker.view as? OMGNativeSurfaceView)
            for (name, theme) in [
                ("dark", OMGNativeTheme(background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.19, alpha: 1),
                                        foreground: NSColor(white: 0.85, alpha: 1))),
                ("light", OMGNativeTheme(background: NSColor(white: 0.96, alpha: 1),
                                         foreground: NSColor(white: 0.15, alpha: 1))),
            ] {
                surface.applyTheme(theme)
                surface.updateLayer()
                let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.effectiveAppearance.performAsCurrentDrawingAppearance {
                    surface.cacheDisplay(in: surface.bounds, to: bitmap)
                }
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/omg-workspace-\(editing ? "edit" : "create")-\(name).png"))
            }
        }
    }
}
