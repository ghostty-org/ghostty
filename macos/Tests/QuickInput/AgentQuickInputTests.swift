import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentQuickInputTests {
    private static var retainedTestWindows: [NSWindow] = []

    @Test func shortcutRoundTripsCanonicalStorageAndDisplay() throws {
        let shortcut = try #require(
            OMGKeyboardShortcut(storageValue: "shift+command+E")
        )
        #expect(shortcut.storageValue == "shift+command+e")
        #expect(shortcut.displayValue == "⇧⌘E")
        #expect(OMGKeyboardShortcut(storageValue: "e") == nil)
        #expect(OMGKeyboardShortcut(storageValue: "command+unknown+e") == nil)
    }

    @Test func queueAndDraftAreScopedToTheirPane() throws {
        let first = UUID()
        let second = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)

        model.present(for: first)
        model.draft = "first prompt"
        let queued = try #require(model.enqueueDraft())
        #expect(model.state(for: first)?.queue == [queued])
        #expect(model.draft.isEmpty)

        model.present(for: second)
        model.draft = "second draft"
        model.dismiss()

        model.present(for: first)
        #expect(model.draft.isEmpty)
        #expect(model.targetQueue == [queued])
        #expect(model.state(for: second)?.draft == "second draft")
    }

    @Test func historyIsPaneScopedAndRecallDoesNotSendOrOverwriteDraft() {
        let first = UUID()
        let second = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: first)
        #expect(!model.recallLastSentText())
        model.recordSentText("first\nmessage 🐱", for: first)
        model.recordSentText("second pane", for: second)
        #expect(model.targetHistory == ["first\nmessage 🐱"])
        #expect(model.recallLastSentText())
        #expect(model.draft == "first\nmessage 🐱")
        #expect(model.isPresented)
        #expect(model.targetQueue.isEmpty)
        model.draft = "unfinished"
        #expect(!model.recallLastSentText())
        #expect(model.draft == "unfinished")
        model.present(for: second)
        #expect(model.recallLastSentText())
        #expect(model.draft == "second pane")
        model.removeState(for: first)
        model.present(for: first)
        #expect(model.targetHistory == ["first\nmessage 🐱"])
        // A newly created pane never inherits a closed pane's history.
        model.present(for: UUID())
        #expect(model.targetHistory.isEmpty)
    }

    @Test func historyIsBoundedDeduplicatedAndMovesWithPaneState() throws {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.recordSentText(" \n", for: surfaceID)
        model.draft = "not yet sent"
        _ = model.enqueueDraft()
        #expect(model.targetHistory.isEmpty)
        for index in 0..<60 { model.recordSentText("message \(index)", for: surfaceID) }
        model.recordSentText("message 59", for: surfaceID)
        #expect(model.targetHistory.count == AgentQuickInputModel.historyLimit)
        #expect(model.targetHistory.first == "message 10")
        #expect(model.targetHistory.last == "message 59")
        let transferred = try #require(model.state(for: surfaceID))
        let destination = AgentQuickInputModel(dockHeight: 252, historyStore: model.historyStore)
        destination.bindHistory(to: UUID(), paneIDs: [surfaceID])
        destination.restore(transferred, for: surfaceID)
        destination.present(for: surfaceID)
        #expect(destination.targetHistory == model.targetHistory)
        let queued = try #require(destination.targetQueue.first)
        destination.editQueuedItem(queued.id, for: surfaceID)
        destination.draft = ""
        #expect(!destination.recallLastSentText())
        destination.useHistoryText("do not overwrite edit")
        #expect(destination.draft.isEmpty)
    }

    @Test func selectingHistoryAppendsWithoutSendingOrChangingQueue() {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: UUID())
        model.draft = "existing draft"
        model.useHistoryText("old\nmessage")
        #expect(model.draft == "existing draft\nold\nmessage")
        model.draft = "existing draft\n"
        model.useHistoryText("another")
        #expect(model.draft == "existing draft\nanother")
        #expect(model.targetQueue.isEmpty)
        #expect(model.targetHistory.isEmpty)
        #expect(model.isPresented)
    }

    @Test func nativeEditorRecallsOnlyOnUnmodifiedUpWithEmptyInput() throws {
        let editor = ComposerTextView()
        var recalled = 0
        editor.onRecallHistory = { recalled += 1; return true }
        let up = try #require(keyEvent(keyCode: 126, modifiers: []))
        editor.keyDown(with: up)
        #expect(recalled == 1)
        editor.string = "unfinished\ntext"
        editor.keyDown(with: up)
        #expect(recalled == 1)
        editor.string = ""
        let optionUp = try #require(keyEvent(keyCode: 126, modifiers: [.option]))
        editor.keyDown(with: optionUp)
        #expect(recalled == 1)
        let shiftUp = try #require(keyEvent(keyCode: 126, modifiers: [.shift]))
        editor.keyDown(with: shiftUp)
        #expect(recalled == 1)
        editor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        editor.keyDown(with: up)
        #expect(recalled == 1)
    }

    @Test func dockDoesNotWaitForAnAnimationToResizeTerminal() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        var interactions = 0
        let token = NotificationCenter.default.addObserver(forName: TerminalSurfaceResizeInteraction.didBegin,
                                                          object: window, queue: .main) { _ in
            MainActor.assumeIsolated { interactions += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        controller.toggleQuickInput()
        controller.dismissQuickInput()
        #expect(interactions == 0, "One-shot composer changes must not put every pane into live-resize deferral")
    }

    @Test func queuedMessageCanBeEditedInPlace() throws {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.draft = "revise this prompt"
        let item = try #require(model.enqueueDraft())
        model.dismiss()

        model.editQueuedItem(item.id, for: surfaceID)
        #expect(model.isPresented)
        #expect(model.isEditingQueuedItem)
        #expect(model.draft == "revise this prompt")
        #expect(model.targetQueue == [item])

        model.draft = "revised prompt"
        #expect(model.confirmQueuedItemEdit(moveToEnd: false))
        #expect(!model.isPresented)
        #expect(!model.isEditingQueuedItem)
        #expect(model.targetQueue.map(\.text) == ["revised prompt"])
        #expect(model.targetQueue.first?.id == item.id)
    }

    @Test func editedMessageCanMoveToQueueEndOrCancel() throws {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.draft = "first"
        let first = try #require(model.enqueueDraft())
        model.draft = "second"
        let second = try #require(model.enqueueDraft())
        model.dismiss()

        model.editQueuedItem(first.id, for: surfaceID)
        model.draft = "first revised"
        #expect(model.confirmQueuedItemEdit(moveToEnd: true))
        #expect(model.targetQueue.map(\.id) == [second.id, first.id])
        #expect(model.targetQueue.map(\.text) == ["second", "first revised"])

        model.editQueuedItem(second.id, for: surfaceID)
        model.draft = "discarded edit"
        model.cancelQueuedItemEdit()
        #expect(model.targetQueue.map(\.text) == ["second", "first revised"])
        #expect(!model.isPresented)
    }

    @Test func nativeEditorConsumesEscapeAndComposerCommands() throws {
        let editor = ComposerTextView()
        var cancelled = 0
        var sent = 0
        var queued = 0
        editor.onCancel = { cancelled += 1 }
        editor.onSend = { sent += 1 }
        editor.onQueue = { queued += 1 }

        let escape = try #require(keyEvent(keyCode: 53, modifiers: []))
        editor.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        editor.keyDown(with: escape)
        #expect(cancelled == 0)

        editor.unmarkText()
        editor.keyDown(with: escape)
        #expect(cancelled == 1)

        let send = try #require(keyEvent(keyCode: 36, modifiers: [.command]))
        #expect(editor.performKeyEquivalent(with: send))
        #expect(sent == 1)

        let queue = try #require(keyEvent(
            keyCode: 36,
            modifiers: [.command, .option]
        ))
        #expect(editor.performKeyEquivalent(with: queue))
        #expect(queued == 1)
    }

    @Test func optionCommandArrowsResolveAsComposerFocusNavigation() {
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 125,
            modifiers: [.option, .command]
        ) == .down)
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 126,
            modifiers: [.option, .command]
        ) == .up)
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 123,
            modifiers: [.option]
        ) == nil)
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 124,
            modifiers: [.option, .command, .shift]
        ) == nil)
    }

    @Test func controlJInsertsNewlineAtSelectionWhenEnabled() throws {
        let editor = ComposerTextView()
        editor.controlJNewlineEnabled = { true }
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        let event = try #require(keyEvent(keyCode: 38, modifiers: [.control]))
        editor.keyDown(with: event)
        #expect(editor.string == "hello\nworld")
        #expect(editor.selectedRange().location == 6)
    }

    @Test func nativeEditorOptionArrowMovesByWord() throws {
        let editor = ComposerTextView()
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        let optionLeft = try #require(keyEvent(
            keyCode: 123,
            modifiers: [.option]
        ))

        editor.keyDown(with: optionLeft)

        #expect(editor.selectedRange().location == 6)
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 124,
            modifiers: [.option, .shift]
        ) == .wordForward(modifySelection: true))
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 126,
            modifiers: [.option]
        ) == .paragraphBeginning(modifySelection: false))
    }

    @Test func nativeEditorImagePasteInsertsAgentTempPath() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(
            name: .init("omg-quick-input-image-\(UUID().uuidString)")
        )
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        let editor = ComposerTextView()
        editor.pasteboard = pasteboard

        editor.paste(nil)

        #expect(editor.string.contains("/omg-paste/omg-paste-"))
        #expect(editor.string.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: editor.string))
        try? FileManager.default.removeItem(atPath: editor.string)
    }

    @Test func nativeEditorImagePasteUsesRemotePathResolver() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(
            name: .init("omg-quick-input-remote-image-\(UUID().uuidString)")
        )
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        let editor = ComposerTextView()
        editor.pasteboard = pasteboard
        var localFile: URL?
        editor.onPasteImage = { file, completion in
            localFile = file
            completion("/tmp/omg-paste-remote.png")
        }

        editor.paste(nil)

        #expect(localFile?.pathExtension == "png")
        #expect(editor.string == "/tmp/omg-paste-remote.png")
        if let localFile { try? FileManager.default.removeItem(at: localFile) }
    }

    @Test func standardEditingShortcutsAreRecognized() {
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "c",
            modifiers: [.command]
        ) == .copy)
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "v",
            modifiers: [.command]
        ) == .paste)
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "z",
            modifiers: [.command, .shift]
        ) == .redo)
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "v",
            modifiers: [.command, .option]
        ) == nil)
    }

    @Test func dockHeightClampsWithoutChangingTerminalMinimum() async throws {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.updateDockHeight(900, availableHeight: 600, persist: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.dockHeight == 440)

        model.updateDockHeight(20, availableHeight: 600, persist: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.dockHeight == AgentQuickInputMetrics.minimumHeight)
    }

    @Test func removingPaneDropsDraftAndQueue() {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.draft = "queued prompt"
        _ = model.enqueueDraft()

        model.removeState(for: surfaceID)

        #expect(model.state(for: surfaceID) == nil)
        #expect(model.targetSurfaceID == nil)
        #expect(!model.isPresented)
    }

    @Test func paneStateCanMoveBetweenControllersWithoutPersistence() throws {
        let surfaceID = UUID()
        let source = AgentQuickInputModel(dockHeight: 252)
        source.present(for: surfaceID)
        source.draft = "draft"
        _ = source.enqueueDraft()
        let state = try #require(source.state(for: surfaceID))

        let destination = AgentQuickInputModel(dockHeight: 252)
        destination.restore(state, for: surfaceID)

        #expect(destination.state(for: surfaceID) == state)
    }

    @Test func queueCardsUseContentWidthAndShrinkToTheLane() {
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: 2,
            availableWidth: 1_000
        ) == AgentQuickInputMetrics.queueMinimumWidth)
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: "resume".count,
            availableWidth: 1_000
        ) == 155)
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: 100,
            availableWidth: 1_000
        ) == AgentQuickInputMetrics.queueMaximumWidth)
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: 100,
            availableWidth: 160
        ) == 136)
        #expect(AgentQuickInputMetrics.queueButtonHitSize == 30)
        #expect(AgentQuickInputMetrics.queueHoverDelayMilliseconds == 300)
    }

    @Test func accessoryHeightReservesFinalLayoutWithoutAnimationSteps() {
        let divider = TerminalShellStyle.dividerWidth
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: false,
            hasQueue: false
        ) == 0)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: true,
            hasQueue: false
        ) == 252 + divider)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: false,
            hasQueue: true
        ) == AgentQuickInputMetrics.queueLaneHeight + divider)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: true,
            hasQueue: true
        ) == 252 + AgentQuickInputMetrics.queueLaneHeight + divider * 2)
    }

    @Test @MainActor func placeholderUsesRealWindowCaretGeometry() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        let editor = ComposerTextView(frame: scrollView.bounds)
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.widthTracksTextView = true
        editor.placeholder = "Type here…"
        scrollView.documentView = editor
        window.contentView = scrollView
        window.makeFirstResponder(editor)
        editor.layoutManager?.ensureLayout(for: try #require(editor.textContainer))

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let screenRect = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: &actualRange
        )
        let localCaretRect = editor.convert(
            window.convertFromScreen(screenRect),
            from: nil
        )
        let origin = editor.placeholderDrawingOrigin()
        let expected = localCaretRect.maxX + 1 / window.backingScaleFactor

        #expect(abs(origin.x - expected) < 0.01)
        #expect(origin.x > localCaretRect.maxX)
        #expect(origin.y == editor.textContainerOrigin.y)
        Self.retainedTestWindows.append(window)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    @Test func agentStartPresentationPolicyRequiresOptInAndFocusedTarget() {
        let activity = TabActivity(
            source: "pi",
            state: .idle,
            label: nil,
            message: nil,
            detail: nil,
            progress: nil,
            icon: nil
        )
        #expect(AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: nil,
            next: activity,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: activity,
            next: activity,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: nil,
            next: activity,
            enabled: false,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: nil,
            next: activity,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: false
        ))
    }

    @Test func agentCompletionPresentationPolicyRequiresNewDoneAndFocusedTarget() {
        #expect(AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .done,
            next: .done,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: false,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: true,
            isAlreadyPresented: true,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: false
        ))
    }

    @Test func dispatchPolicyOnlyAcceptsNewDoneTransition() {
        #expect(AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .working,
            next: .done
        ))
        #expect(AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .needsAttention,
            next: .done
        ))
        #expect(!AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .working,
            next: .needsAttention
        ))
        #expect(!AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .done,
            next: .done
        ))
        #expect(!AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .done,
            next: .idle
        ))
    }

    @Test func composerTextViewUsesIsolatedUndoManager() {
        let editor = ComposerTextView()
        let window = NSWindow()
        window.contentView = editor
        #expect(editor.undoManager != nil)
        #expect(editor.undoManager !== window.undoManager)
    }
}
