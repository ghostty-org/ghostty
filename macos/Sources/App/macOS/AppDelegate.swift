import AppKit
import UserNotifications
import OSLog
import Sparkle
import GhosttyKit

class AppDelegate: NSObject,
                    ObservableObject,
                    NSApplicationDelegate,
                    UNUserNotificationCenterDelegate,
                    GhosttyAppDelegate
{
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )

    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Ghostty config
    @IBOutlet private var menuAbout: NSMenuItem?
    @IBOutlet private var menuServices: NSMenu?
    @IBOutlet private var menuCheckForUpdates: NSMenuItem?
    @IBOutlet private var menuOpenConfig: NSMenuItem?
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuSecureInput: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?

    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitRight: NSMenuItem?
    @IBOutlet private var menuSplitLeft: NSMenuItem?
    @IBOutlet private var menuSplitDown: NSMenuItem?
    @IBOutlet private var menuSplitUp: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseTab: NSMenuItem?
    @IBOutlet private var menuCloseWindow: NSMenuItem?
    @IBOutlet private var menuCloseAllWindows: NSMenuItem?

    @IBOutlet private var menuUndo: NSMenuItem?
    @IBOutlet private var menuRedo: NSMenuItem?
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?
    @IBOutlet private var menuPasteSelection: NSMenuItem?
    @IBOutlet private var menuSelectAll: NSMenuItem?

    @IBOutlet private var menuToggleVisibility: NSMenuItem?
    @IBOutlet private var menuToggleFullScreen: NSMenuItem?
    @IBOutlet private var menuBringAllToFront: NSMenuItem?
    @IBOutlet private var menuZoomSplit: NSMenuItem?
    @IBOutlet private var menuPreviousSplit: NSMenuItem?
    @IBOutlet private var menuNextSplit: NSMenuItem?
    @IBOutlet private var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet private var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet private var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet private var menuSelectSplitRight: NSMenuItem?
    @IBOutlet private var menuReturnToDefaultSize: NSMenuItem?
    @IBOutlet private var menuFloatOnTop: NSMenuItem?
    @IBOutlet private var menuUseAsDefault: NSMenuItem?

    @IBOutlet private var menuIncreaseFontSize: NSMenuItem?
    @IBOutlet private var menuDecreaseFontSize: NSMenuItem?
    @IBOutlet private var menuResetFontSize: NSMenuItem?
    @IBOutlet private var menuChangeTitle: NSMenuItem?
    @IBOutlet private var menuQuickTerminal: NSMenuItem?
    @IBOutlet private var menuTerminalInspector: NSMenuItem?
    @IBOutlet private var menuCommandPalette: NSMenuItem?

    @IBOutlet private var menuEqualizeSplits: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerUp: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerDown: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerLeft: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerRight: NSMenuItem?

    /// The dock menu
    private var dockMenu: NSMenu = NSMenu()

    /// This is only true before application has become active.
    private var applicationHasBecomeActive: Bool = false

    /// This is set in applicationDidFinishLaunching with the system uptime so we can determine the
    /// seconds since the process was launched.
    private var applicationLaunchTime: TimeInterval = 0

    /// This is the current configuration from the Ghostty configuration that we need.
    private var derivedConfig: DerivedConfig = DerivedConfig()

    /// The ghostty global state. Only one per process.
    let ghostty: Ghostty.App = Ghostty.App()

    /// The global undo manager for app-level state such as window restoration.
    lazy var undoManager = ExpiringUndoManager()

    /// Our quick terminal. This starts out uninitialized and only initializes if used.
    private var quickController: QuickTerminalController? = nil

    /// Manages updates
    let updaterController: SPUStandardUpdaterController
    let updaterDelegate: UpdaterDelegate = UpdaterDelegate()

    /// The elapsed time since the process was started
    var timeSinceLaunch: TimeInterval {
        return ProcessInfo.processInfo.systemUptime - applicationLaunchTime
    }

    /// Tracks the windows that we hid for toggleVisibility.
    private var hiddenState: ToggleVisibilityState? = nil

    /// The observer for the app appearance.
    private var appearanceObserver: NSKeyValueObservation? = nil

    /// The custom app icon image that is currently in use.
    @Published private(set) var appIcon: NSImage? = nil {
        didSet {
            NSApplication.shared.applicationIconImage = appIcon
        }
    }

    override init() {
        updaterController = SPUStandardUpdaterController(
            // Important: we must not start the updater here because we need to read our configuration
            // first to determine whether we're automatically checking, downloading, etc. The updater
            // is started later in applicationDidFinishLaunching
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        super.init()

        ghostty.delegate = self
    }

    //MARK: - NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Disable the automatic full screen menu item because we handle
            // it manually.
            "NSFullScreenMenuItemEverywhere": false,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // System settings overrides
        UserDefaults.standard.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])

        // Store our start time
        applicationLaunchTime = ProcessInfo.processInfo.systemUptime

        // Check if secure input was enabled when we last quit.
        if (UserDefaults.standard.bool(forKey: "SecureInput") != SecureInput.shared.enabled) {
            toggleSecureInput(self)
        }

        // Initial config loading
        ghosttyConfigDidChange(config: ghostty.config)

        // Start our update checker.
        updaterController.startUpdater()

        // Register our service provider. This must happen after everything is initialized.
        NSApp.servicesProvider = ServiceProvider()

        // This registers the Ghostty => Services menu to exist.
        NSApp.servicesMenu = menuServices
        
        // Setup a local event monitor for app-level keyboard shortcuts. See
        // localEventHandler for more info why.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: localEventHandler)

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickTerminalDidChangeVisibility),
            name: .quickTerminalDidChangeVisibility,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewWindow(_:)),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewTab(_:)),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)

        // Configure user notifications
        let actions = [
            UNNotificationAction(identifier: Ghostty.userNotificationActionShow, title: "Show")
        ]

        let center = UNUserNotificationCenter.current()

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Ghostty.userNotificationCategory,
                actions: actions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
        center.delegate = self

        // Observe our appearance so we can report the correct value to libghostty.
        self.appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
             options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            guard let app = self.ghostty.app else { return }
            let scheme: ghostty_color_scheme_e
            if (appearance.isDark) {
                scheme = GHOSTTY_COLOR_SCHEME_DARK
            } else {
                scheme = GHOSTTY_COLOR_SCHEME_LIGHT
            }

            ghostty_app_set_color_scheme(app, scheme)
        }

        // Setup our menu
        setupMenuImages()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If we're back manually then clear the hidden state because macOS handles it.
        self.hiddenState = nil

        // Clear the dock badge when the app becomes active
        self.setDockBadge(nil)

        // First launch stuff
        if (!applicationHasBecomeActive) {
            applicationHasBecomeActive = true

            // Let's launch our first window. We only do this if we have no other windows. It
            // is possible to have other windows in a few scenarios:
            //   - if we're opening a URL since `application(_:openFile:)` is called before this.
            //   - if we're restoring from persisted state
            if TerminalController.all.isEmpty && derivedConfig.initialWindow {
                undoManager.disableUndoRegistration()
                _ = TerminalController.newWindow(ghostty)
                undoManager.enableUndoRegistration()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return derivedConfig.shouldQuitAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = NSApplication.shared.windows
        if (windows.isEmpty) { return .terminateNow }

        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        //
        // NOTE(mitchellh): I don't think we need this check at all anymore. I'm keeping it
        // here because I don't want to remove it in a patch release cycle but we should
        // target removing it soon.
        if (self.quickController == nil && windows.allSatisfy { !$0.isVisible }) {
            return .terminateNow
        }

        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        why: if let event = NSAppleEventManager.shared().currentAppleEvent {
            // If all Ghostty windows are in the background (i.e. you Cmd-Q from the Cmd-Tab
            // view), then this is null. I don't know why (pun intended) but we have to
            // guard against it.
            guard let keyword = AEKeyword("why?") else { break why }

            if let why = event.attributeDescriptor(forKeyword: keyword) {
                switch (why.typeCodeValue) {
                case kAEShutDown:
                    fallthrough

                case kAERestart:
                    fallthrough

                case kAEReallyLogOut:
                    return .terminateNow

                default:
                    break
                }
            }
        }

        // If our app says we don't need to confirm, we can exit now.
        if (!ghostty.needsConfirmQuit) { return .terminateNow }

        // We have some visible window. Show an app-wide modal to confirm quitting.
        let alert = NSAlert()
        alert.messageText = "Quit Ghostty?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close Ghostty")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch (alert.runModal()) {
        case .alertFirstButtonReturn:
            return .terminateNow

        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // We have no notifications we want to persist after death,
        // so remove them all now. In the future we may want to be
        // more selective and only remove surface-targeted notifications.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// This is called when the application is already open and someone double-clicks the icon
    /// or clicks the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If we have visible windows then we allow macOS to do its default behavior
        // of focusing one of them.
        guard !flag else { return true }

        // If we have any windows in our terminal manager we don't do anything.
        // This is possible with flag set to false if there a race where the
        // window is still initializing and is not visible but the user clicked
        // the dock icon.
        guard TerminalController.all.isEmpty else { return true }

        // If the application isn't active yet then we don't want to process
        // this because we're not ready. This happens sometimes in Xcode runs
        // but I haven't seen it happen in releases. I'm unsure why.
        guard applicationHasBecomeActive else { return true }

        // No visible windows, open a new one.
        _ = TerminalController.newWindow(ghostty)
        return false
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Ghostty will validate as well but we can avoid creating an entirely new
        // surface by doing our own validation here. We can also show a useful error
        // this way.

        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else { return false }

        // Initialize the surface config which will be used to create the tab or window for the opened file.
        var config = Ghostty.SurfaceConfiguration()

        if (isDirectory.boolValue) {
            // When opening a directory, create a new tab in the main
            // window with that as the working directory.
            // If no windows exist, a new one will be created.
            config.workingDirectory = filename
            _ = TerminalController.newTab(ghostty, withBaseConfig: config)
        } else {
            // When opening a file, open a new window with that file as the command,
            // and its parent directory as the working directory.
            config.command = filename
            config.workingDirectory = (filename as NSString).deletingLastPathComponent
            _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
        }

        return true
    }

    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }

    /// Setup all the images for our menu items.
    private func setupMenuImages() {
        // Note: This COULD Be done all in the xib file, but I find it easier to
        // modify this stuff as code.
        self.menuAbout?.setImageIfDesired(systemSymbolName: "info.circle")
        self.menuCheckForUpdates?.setImageIfDesired(systemSymbolName: "square.and.arrow.down")
        self.menuOpenConfig?.setImageIfDesired(systemSymbolName: "gear")
        self.menuReloadConfig?.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90")
        self.menuSecureInput?.setImageIfDesired(systemSymbolName: "lock.display")
        self.menuNewWindow?.setImageIfDesired(systemSymbolName: "macwindow.badge.plus")
        self.menuNewTab?.setImageIfDesired(systemSymbolName: "macwindow")
        self.menuSplitRight?.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
        self.menuSplitLeft?.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
        self.menuSplitUp?.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")
        self.menuSplitDown?.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
        self.menuClose?.setImageIfDesired(systemSymbolName: "xmark")
        self.menuIncreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.larger")
        self.menuResetFontSize?.setImageIfDesired(systemSymbolName: "textformat.size")
        self.menuDecreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.smaller")
        self.menuCommandPalette?.setImageIfDesired(systemSymbolName: "filemenu.and.selection")
        self.menuQuickTerminal?.setImageIfDesired(systemSymbolName: "apple.terminal")
        self.menuChangeTitle?.setImageIfDesired(systemSymbolName: "pencil.line")
        self.menuTerminalInspector?.setImageIfDesired(systemSymbolName: "scope")
        self.menuToggleFullScreen?.setImageIfDesired(systemSymbolName: "square.arrowtriangle.4.outward")
        self.menuToggleVisibility?.setImageIfDesired(systemSymbolName: "eye")
        self.menuZoomSplit?.setImageIfDesired(systemSymbolName: "arrow.up.left.and.arrow.down.right")
        self.menuPreviousSplit?.setImageIfDesired(systemSymbolName: "chevron.backward.2")
        self.menuNextSplit?.setImageIfDesired(systemSymbolName: "chevron.forward.2")
        self.menuEqualizeSplits?.setImageIfDesired(systemSymbolName: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle")
        self.menuSelectSplitLeft?.setImageIfDesired(systemSymbolName: "arrow.left")
        self.menuSelectSplitRight?.setImageIfDesired(systemSymbolName: "arrow.right")
        self.menuSelectSplitAbove?.setImageIfDesired(systemSymbolName: "arrow.up")
        self.menuSelectSplitBelow?.setImageIfDesired(systemSymbolName: "arrow.down")
        self.menuMoveSplitDividerUp?.setImageIfDesired(systemSymbolName: "arrow.up.to.line")
        self.menuMoveSplitDividerDown?.setImageIfDesired(systemSymbolName: "arrow.down.to.line")
        self.menuMoveSplitDividerLeft?.setImageIfDesired(systemSymbolName: "arrow.left.to.line")
        self.menuMoveSplitDividerRight?.setImageIfDesired(systemSymbolName: "arrow.right.to.line")
        self.menuFloatOnTop?.setImageIfDesired(systemSymbolName: "square.3.layers.3d.top.filled")
    }

    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    private func syncMenuShortcuts(_ config: Ghostty.Config) {
        guard ghostty.readiness == .ready else { return }

        syncMenuShortcut(config, action: "check_for_updates", menuItem: self.menuCheckForUpdates)
        syncMenuShortcut(config, action: "open_config", menuItem: self.menuOpenConfig)
        syncMenuShortcut(config, action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(config, action: "quit", menuItem: self.menuQuit)

        syncMenuShortcut(config, action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(config, action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(config, action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(config, action: "close_tab", menuItem: self.menuCloseTab)
        syncMenuShortcut(config, action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(config, action: "close_all_windows", menuItem: self.menuCloseAllWindows)
        syncMenuShortcut(config, action: "new_split:right", menuItem: self.menuSplitRight)
        syncMenuShortcut(config, action: "new_split:left", menuItem: self.menuSplitLeft)
        syncMenuShortcut(config, action: "new_split:down", menuItem: self.menuSplitDown)
        syncMenuShortcut(config, action: "new_split:up", menuItem: self.menuSplitUp)

        syncMenuShortcut(config, action: "undo", menuItem: self.menuUndo)
        syncMenuShortcut(config, action: "redo", menuItem: self.menuRedo)
        syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(config, action: "paste_from_clipboard", menuItem: self.menuPaste)
        syncMenuShortcut(config, action: "paste_from_selection", menuItem: self.menuPasteSelection)
        syncMenuShortcut(config, action: "select_all", menuItem: self.menuSelectAll)

        syncMenuShortcut(config, action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(config, action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(config, action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(config, action: "goto_split:up", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(config, action: "goto_split:down", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(config, action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(config, action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        syncMenuShortcut(config, action: "resize_split:up,10", menuItem: self.menuMoveSplitDividerUp)
        syncMenuShortcut(config, action: "resize_split:down,10", menuItem: self.menuMoveSplitDividerDown)
        syncMenuShortcut(config, action: "resize_split:right,10", menuItem: self.menuMoveSplitDividerRight)
        syncMenuShortcut(config, action: "resize_split:left,10", menuItem: self.menuMoveSplitDividerLeft)
        syncMenuShortcut(config, action: "equalize_splits", menuItem: self.menuEqualizeSplits)
        syncMenuShortcut(config, action: "reset_window_size", menuItem: self.menuReturnToDefaultSize)

        syncMenuShortcut(config, action: "increase_font_size:1", menuItem: self.menuIncreaseFontSize)
        syncMenuShortcut(config, action: "decrease_font_size:1", menuItem: self.menuDecreaseFontSize)
        syncMenuShortcut(config, action: "reset_font_size", menuItem: self.menuResetFontSize)
        syncMenuShortcut(config, action: "prompt_surface_title", menuItem: self.menuChangeTitle)
        syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: self.menuQuickTerminal)
        syncMenuShortcut(config, action: "toggle_visibility", menuItem: self.menuToggleVisibility)
        syncMenuShortcut(config, action: "toggle_window_float_on_top", menuItem: self.menuFloatOnTop)
        syncMenuShortcut(config, action: "inspector:toggle", menuItem: self.menuTerminalInspector)
        syncMenuShortcut(config, action: "toggle_command_palette", menuItem: self.menuCommandPalette)

        syncMenuShortcut(config, action: "toggle_secure_input", menuItem: self.menuSecureInput)

        // This menu item is NOT synced with the configuration because it disables macOS
        // global fullscreen keyboard shortcut. The shortcut in the Ghostty config will continue
        // to work but it won't be reflected in the menu item.
        //
        // syncMenuShortcut(config, action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)

        // Dock menu
        reloadDockMenu()
    }

    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    private func syncMenuShortcut(_ config: Ghostty.Config, action: String, menuItem: NSMenuItem?) {
        guard let menu = menuItem else { return }
        guard let shortcut = config.keyboardShortcut(for: action) else {
            // No shortcut, clear the menu item
            menu.keyEquivalent = ""
            menu.keyEquivalentModifierMask = []
            return
        }

        menu.keyEquivalent = shortcut.key.character.description
        menu.keyEquivalentModifierMask = .init(swiftUIFlags: shortcut.modifiers)
    }

    // MARK: Notifications and Events

    /// This handles events from the NSEvent.addLocalEventMonitor. We use this so we can get
    /// events without any terminal windows open.
    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .keyDown:
            localEventKeyDown(event)

        default:
            event
        }
    }

    private func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
        // If we have a main window then we don't process any of the keys
        // because we let it capture and propagate.
        guard NSApp.mainWindow == nil else { return event }

        // If this event as-is would result in a key binding then we send it.
        if let app = ghostty.app {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            let match = (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                if !ghostty_app_key_is_binding(app, ghosttyEvent) {
                    return false
                }

                return ghostty_app_key(app, ghosttyEvent)
            }

            // If the key was handled by Ghostty we stop the event chain. If
            // the key wasn't handled then we let it fall through and continue
            // processing. This is important because some bindings may have no
            // affect at this scope.
            if match {
                return nil
            }
        }

        // If this event would be handled by our menu then we do nothing.
        if let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return nil
        }

        // If we reach this point then we try to process the key event
        // through the Ghostty key mechanism.

        // Ghostty must be loaded
        guard let ghostty = self.ghostty.app else { return event }

        // Build our event input and call ghostty
        if (ghostty_app_key(ghostty, event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS))) {
            // The key was used so we want to stop it from going to our Mac app
            Ghostty.logger.debug("local key event handled event=\(event)")
            return nil
        }

        return event
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        syncFloatOnTopMenu(notification.object as? NSWindow)
    }

    @objc private func quickTerminalDidChangeVisibility(_ notification: Notification) {
        guard let quickController = notification.object as? QuickTerminalController else { return }
        self.menuQuickTerminal?.state = if (quickController.visible) { .on } else { .off }
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a surface one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        ghosttyConfigDidChange(config: config)
    }

    @objc private func ghosttyBellDidRing(_ notification: Notification) {
        if (ghostty.config.bellFeatures.contains(.attention)) {
            // Bounce the dock icon if we're not focused.
            NSApp.requestUserAttention(.informationalRequest)

            // Handle setting the dock badge based on permissions
            ghosttyUpdateBadgeForBell()
        }
    }

    private func ghosttyUpdateBadgeForBell() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                // Already authorized, check badge setting and set if enabled
                if settings.badgeSetting == .enabled {
                    DispatchQueue.main.async {
                        self.setDockBadge()
                    }
                }

            case .notDetermined:
                // Not determined yet, request authorization for badge
                center.requestAuthorization(options: [.badge]) { granted, error in
                    if let error = error {
                        Self.logger.warning("Error requesting badge authorization: \(error)")
                        return
                    }

                    if granted {
                        // Permission granted, set the badge
                        DispatchQueue.main.async {
                            self.setDockBadge()
                        }
                    }
                }

            case .denied, .provisional, .ephemeral:
                // In these known non-authorized states, do not attempt to set the badge.
                break

            @unknown default:
                // Handle future unknown states by doing nothing.
                break
            }
        }
    }

    @objc private func ghosttyNewWindow(_ notification: Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
    }

    @objc private func ghosttyNewTab(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }

        // We only want to listen to new tabs if the focused parent is
        // a regular terminal controller.
        guard window.windowController is TerminalController else { return }

        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }

    private func setDockBadge(_ label: String? = "•") {
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
    }

    private func ghosttyConfigDidChange(config: Ghostty.Config) {
        // Update the config we need to store
        self.derivedConfig = DerivedConfig(config)

        // Depending on the "window-save-state" setting we have to set the NSQuitAlwaysKeepsWindows
        // configuration. This is the only way to carefully control whether macOS invokes the
        // state restoration system.
        switch (config.windowSaveState) {
        case "never": UserDefaults.standard.setValue(false, forKey: "NSQuitAlwaysKeepsWindows")
        case "always": UserDefaults.standard.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        case "default": fallthrough
        default: UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
        }

        // Sync our auto-update settings. If SUEnableAutomaticChecks (in our Info.plist) is
        // explicitly false (NO), auto-updates are disabled. Otherwise, we use the behavior
        // defined by our "auto-update" configuration (if set) or fall back to Sparkle
        // user-based defaults.
        if Bundle.main.infoDictionary?["SUEnableAutomaticChecks"] as? Bool == false {
            updaterController.updater.automaticallyChecksForUpdates = false
            updaterController.updater.automaticallyDownloadsUpdates = false
        } else if let autoUpdate = config.autoUpdate {
            updaterController.updater.automaticallyChecksForUpdates =
                autoUpdate == .check || autoUpdate == .download
            updaterController.updater.automaticallyDownloadsUpdates =
                autoUpdate == .download
        }

        // Config could change keybindings, so update everything that depends on that
        syncMenuShortcuts(config)
        TerminalController.all.forEach { $0.relabelTabs() }

        // Config could change window appearance. We wrap this in an async queue because when
        // this is called as part of application launch it can deadlock with an internal
        // AppKit mutex on the appearance.
        DispatchQueue.main.async { self.syncAppearance(config: config) }

        // Decide whether to hide/unhide app from dock and app switcher
        switch (config.macosHidden) {
        case .never:
            NSApp.setActivationPolicy(.regular)

        case .always:
            NSApp.setActivationPolicy(.accessory)
        }

        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = config.errors
        if (c.errors.count > 0) {
            if (c.window == nil || !c.window!.isVisible) {
                c.showWindow(self)
            }
        }

        // We need to handle our global event tap depending on if there are global
        // events that we care about in Ghostty.
        if (ghostty_app_has_global_keybinds(ghostty.app!)) {
            if (timeSinceLaunch > 5) {
                // If the process has been running for awhile we enable right away
                // because no windows are likely to pop up.
                GlobalEventTap.shared.enable()
            } else {
                // If the process just started, we wait a couple seconds to allow
                // the initial windows and so on to load so our permissions dialog
                // doesn't get buried.
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                    GlobalEventTap.shared.enable()
                }
            }
        } else {
            GlobalEventTap.shared.disable()
        }

        switch (config.macosIcon) {
        case .official:
            self.appIcon = nil
            break

        case .blueprint:
            self.appIcon = NSImage(named: "BlueprintImage")!

        case .chalkboard:
            self.appIcon = NSImage(named: "ChalkboardImage")!

        case .glass:
            self.appIcon = NSImage(named: "GlassImage")!

        case .holographic:
            self.appIcon = NSImage(named: "HolographicImage")!

        case .microchip:
            self.appIcon = NSImage(named: "MicrochipImage")!

        case .paper:
            self.appIcon = NSImage(named: "PaperImage")!

        case .retro:
            self.appIcon = NSImage(named: "RetroImage")!

        case .xray:
            self.appIcon = NSImage(named: "XrayImage")!

        case .customStyle:
            guard let ghostColor = config.macosIconGhostColor else { break }
            guard let screenColors = config.macosIconScreenColor else { break }
            guard let icon = ColorizedGhosttyIcon(
                screenColors: screenColors,
                ghostColor: ghostColor,
                frame: config.macosIconFrame
            ).makeImage() else { break }
            self.appIcon = icon
        }
    }

    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance(config: Ghostty.Config) {
        NSApplication.shared.appearance = .init(ghosttyConfig: config)
    }

    //MARK: - Restorable State

    /// We support NSSecureCoding for restorable state. Required as of macOS Sonoma (14) but a good idea anyways.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
        Self.logger.debug("application will save window state")
    }

    func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
        Self.logger.debug("application will restore window state")
    }

    //MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive: UNNotificationResponse,
        withCompletionHandler: () -> Void
    ) {
        ghostty.handleUserNotification(response: didReceive)
        withCompletionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent: UNNotification,
        withCompletionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        let shouldPresent = ghostty.shouldPresentNotification(notification: willPresent)
        let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .sound] : []
        withCompletionHandler(options)
    }

    //MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for c in TerminalController.all {
            for view in c.surfaceTree {
                if view.uuid == uuid {
                    return view
                }
            }
        }

        return nil
    }

    //MARK: - Dock Menu

    private func reloadDockMenu() {
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")

        dockMenu.removeAllItems()
        dockMenu.addItem(newWindow)
        dockMenu.addItem(newTab)
    }

    //MARK: - Global State

    func setSecureInput(_ mode: Ghostty.SetSecureInput) {
        let input = SecureInput.shared
        switch (mode) {
        case .on:
            input.global = true

        case .off:
            input.global = false

        case .toggle:
            input.global.toggle()
        }
        self.menuSecureInput?.state = if (input.global) { .on } else { .off }
        UserDefaults.standard.set(input.global, forKey: "SecureInput")
    }

    //MARK: - IB Actions

    @IBAction func openConfig(_ sender: Any?) {
        ghostty.openConfig()
    }

    @IBAction func reloadConfig(_ sender: Any?) {
        ghostty.reloadConfig()
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @IBAction func newWindow(_ sender: Any?) {
        _ = TerminalController.newWindow(ghostty)

        // We also activate our app so that it becomes front. This may be
        // necessary for the dock menu.
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func newTab(_ sender: Any?) {
        _ = TerminalController.newTab(ghostty)

        // We also activate our app so that it becomes front. This may be
        // necessary for the dock menu.
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func closeAllWindows(_ sender: Any?) {
        TerminalController.closeAllWindows()
        AboutController.shared.hide()
    }

    @IBAction func showAbout(_ sender: Any?) {
        AboutController.shared.show()
    }

    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://ghostty.org/docs") else { return }
        NSWorkspace.shared.open(url)
    }

    @IBAction func toggleSecureInput(_ sender: Any) {
        setSecureInput(.toggle)
    }

    @IBAction func toggleQuickTerminal(_ sender: Any) {
        if quickController == nil {
            quickController = QuickTerminalController(
                ghostty,
                position: derivedConfig.quickTerminalPosition
            )
        }

        guard let quickController = self.quickController else { return }
        quickController.toggle()
    }

    /// Toggles visibility of all Ghosty Terminal windows. When hidden, activates Ghostty as the frontmost application
    @IBAction func toggleVisibility(_ sender: Any) {
        // If we have focus, then we hide all windows.
        if NSApp.isActive {
            // Toggle visibility doesn't do anything if the focused window is native
            // fullscreen. This is only relevant if Ghostty is active.
            guard let keyWindow = NSApp.keyWindow,
                  !keyWindow.styleMask.contains(.fullScreen) else { return }

            // Keep track of our hidden state to restore properly
            self.hiddenState = .init()
            NSApp.hide(nil)
            return
        }

        // If we're not active, we want to become active
        NSApp.activate(ignoringOtherApps: true)

        // Bring all windows to the front. Note: we don't use NSApp.unhide because
        // that will unhide ALL hidden windows. We want to only bring forward the
        // ones that we hid.
        hiddenState?.restore()
        hiddenState = nil
    }

    @IBAction func bringAllToFront(_ sender: Any) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSApplication.shared.arrangeInFront(sender)
    }

    @IBAction func undo(_ sender: Any?) {
        undoManager.undo()
    }

    @IBAction func redo(_ sender: Any?) {
        undoManager.redo()
    }

    private struct DerivedConfig {
        let initialWindow: Bool
        let shouldQuitAfterLastWindowClosed: Bool
        let quickTerminalPosition: QuickTerminalPosition

        init() {
            self.initialWindow = true
            self.shouldQuitAfterLastWindowClosed = false
            self.quickTerminalPosition = .top
        }

        init(_ config: Ghostty.Config) {
            self.initialWindow = config.initialWindow
            self.shouldQuitAfterLastWindowClosed = config.shouldQuitAfterLastWindowClosed
            self.quickTerminalPosition = config.quickTerminalPosition
        }
    }

    private struct ToggleVisibilityState {
        let hiddenWindows: [Weak<NSWindow>]
        let keyWindow: Weak<NSWindow>?

        init() {
            // We need to know the key window so that we can bring focus back to the
            // right window if it was hidden.
            self.keyWindow = if let keyWindow = NSApp.keyWindow {
                .init(keyWindow)
            } else {
                nil
            }

            // We need to keep track of the windows that were visible because we only
            // want to bring back these windows if we remove the toggle.
            //
            // We also ignore fullscreen windows because they don't hide anyways.
            self.hiddenWindows = NSApp.windows.filter {
                $0.isVisible &&
                !$0.styleMask.contains(.fullScreen)
            }.map { Weak($0) }
        }

        func restore() {
            hiddenWindows.forEach { $0.value?.orderFrontRegardless() }
            keyWindow?.value?.makeKey()
        }
    }
}

// MARK: Floating Windows

extension AppDelegate {
    func syncFloatOnTopMenu(_ window: NSWindow?) {
        guard let window = (window ?? NSApp.keyWindow) as? TerminalWindow else {
            // If some other window became key we always turn this off
            self.menuFloatOnTop?.state = .off
            return
        }

        self.menuFloatOnTop?.state = window.level == .floating ? .on : .off
    }

    @IBAction func floatOnTop(_ menuItem: NSMenuItem) {
        menuItem.state = menuItem.state == .on ? .off : .on
        guard let window = NSApp.keyWindow else { return }
        window.level = menuItem.state == .on ? .floating : .normal
    }

    @IBAction func useAsDefault(_ sender: NSMenuItem) {
        let ud = UserDefaults.standard
        let key = TerminalWindow.defaultLevelKey
        if (menuFloatOnTop?.state == .on) {
            ud.set(NSWindow.Level.floating, forKey: key)
        } else {
            ud.removeObject(forKey: key)
        }
    }
}

// MARK: NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(floatOnTop(_:)),
            #selector(useAsDefault(_:)):
            // Float on top items only active if the key window is a primary
            // terminal window (not quick terminal).
            return NSApp.keyWindow is TerminalWindow

        case #selector(undo(_:)):
            if undoManager.canUndo {
                item.title = "Undo \(undoManager.undoActionName)"
            } else {
                item.title = "Undo"
            }
            return undoManager.canUndo

        case #selector(redo(_:)):
            if undoManager.canRedo {
                item.title = "Redo \(undoManager.redoActionName)"
            } else {
                item.title = "Redo"
            }
            return undoManager.canRedo

        default:
            return true
        }
    }
}
