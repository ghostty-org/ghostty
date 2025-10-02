//
//  SettingsController.swift
//  Ghostty
//
//  Created by luca on 02.10.2025.
//
import AppKit
import GhosttyKit
import SwiftUI

class SettingsController: NSWindowController, NSWindowDelegate {
    private let surfaceView: Ghostty.SurfaceView

    init(ghosttyApp: ghostty_app_t) {
        var config = Ghostty.SurfaceConfiguration()
        config.waitAfterCommand = true
        config.command = "bash"
        config.workingDirectory = Bundle.main.resourcePath
        surfaceView = .init(ghosttyApp, baseConfig: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .unifiedTitleAndToolbar, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
//        window.titlebarAppearsTransparent = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(surfaceView: surfaceView))
        super.init(window: window)
        windowFrameAutosaveName = "SettingsWindow"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSWindowController

    func show(sender: Any?) {
        window?.makeKeyAndOrderFront(sender)
    }
}
