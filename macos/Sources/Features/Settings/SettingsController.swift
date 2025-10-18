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
    private static var shared: SettingsController?

    static func controller(for ghosttyApp: ghostty_app_t) -> SettingsController {
        if let shared {
            return shared
        } else {
            let newController = SettingsController(ghosttyApp: ghosttyApp)
            shared = newController
            return newController
        }
    }

    private let surfaceView: Ghostty.SurfaceView
    private let config: Ghostty.ConfigFile
    private init(ghosttyApp: ghostty_app_t) {
        var config = Ghostty.SurfaceConfiguration()
        config.waitAfterCommand = true
        config.command = "sh" // we use sh to remove 'Last login at the top'
        config.workingDirectory = Bundle.main.resourcePath
        surfaceView = .init(ghosttyApp, baseConfig: config, isFocused: false)
        surfaceView.isEnabled = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .unifiedTitleAndToolbar, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.config = .init()
        super.init(window: window)
        windowFrameAutosaveName = "SettingsWindow"
        window.tabbingMode = .disallowed
        window.collectionBehavior = .fullScreenNone
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView()
            .environmentObject(self.config)
            .ghosttySurfaceView(surfaceView)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSWindowController

    func show(sender: Any?) {
        window?.makeKeyAndOrderFront(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event)
    }

    // responds to file menu
    @objc func close(_ sender: Any) {
        window?.performClose(sender)
    }
}
