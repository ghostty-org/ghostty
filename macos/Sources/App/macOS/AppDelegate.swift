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
    @IBOutlet private var menuServices: NSMenu?
    @IBOutlet private var menuCheckForUpdates: NSMenuItem?
    @IBOutlet private var menuOpenConfig: NSMenuItem?
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?
    
    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitRight: NSMenuItem?
    @IBOutlet private var menuSplitDown: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseWindow: NSMenuItem?
    @IBOutlet private var menuCloseAllWindows: NSMenuItem?
    
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?
    @IBOutlet private var menuSelectAll: NSMenuItem?

    @IBOutlet private var menuToggleFullScreen: NSMenuItem?
    @IBOutlet private var menuZoomSplit: NSMenuItem?
    @IBOutlet private var menuPreviousSplit: NSMenuItem?
    @IBOutlet private var menuNextSplit: NSMenuItem?
    @IBOutlet private var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet private var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet private var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet private var menuSelectSplitRight: NSMenuItem?

    @IBOutlet private var menuIncreaseFontSize: NSMenuItem?
    @IBOutlet private var menuDecreaseFontSize: NSMenuItem?
    @IBOutlet private var menuResetFontSize: NSMenuItem?
    @IBOutlet private var menuTerminalInspector: NSMenuItem?

    @IBOutlet private var menuEqualizeSplits: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerUp: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerDown: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerLeft: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerRight: NSMenuItem?

    /// The dock menu
    private var dockMenu: NSMenu = NSMenu()
    
    /// This is only true before application has become active.
    private var applicationHasBecomeActive: Bool = false
    
    /// The ghostty global state. Only one per process.
    let ghostty: Ghostty.App = Ghostty.App()
    
    /// Manages our terminal windows.
    let terminalManager: TerminalManager
    
    /// Manages updates
    let updaterController: SPUStandardUpdaterController
    let updaterDelegate: UpdaterDelegate = UpdaterDelegate()
    
    override init() {
        terminalManager = TerminalManager(ghostty)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
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
        
        // Hook up updater menu
        menuCheckForUpdates?.target = updaterController
        menuCheckForUpdates?.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        
        // Initial config loading
        configDidReload(ghostty)
        
        updaterController.updater.updateCheckInterval = 60
        updaterController.updater.automaticallyChecksForUpdates =
            ghostty.config.autoUpdates == "check" || ghostty.config.autoUpdates == "download"
        updaterController.updater.automaticallyDownloadsUpdates =
            ghostty.config.autoUpdates == "download"
        
        // Register our service provider. This must happen after everything is initialized.
        NSApp.servicesProvider = ServiceProvider()
        
        // This registers the Ghostty => Services menu to exist.
        NSApp.servicesMenu = menuServices

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
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !applicationHasBecomeActive else { return }
        applicationHasBecomeActive = true
        
        // Let's launch our first window. We only do this if we have no other windows. It
        // is possible to have other windows in a few scenarios:
        //   - if we're opening a URL since `application(_:openFile:)` is called before this.
        //   - if we're restoring from persisted state
        if terminalManager.windows.count == 0 {
            terminalManager.newWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return ghostty.config.shouldQuitAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = NSApplication.shared.windows
        if (windows.isEmpty) { return .terminateNow }
        
        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        if (windows.allSatisfy { !$0.isVisible }) { return .terminateNow }
        
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
    
    /// This is called when the application is already open and someone double-clicks the icon
    /// or clicks the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If we have visible windows then we allow macOS to do its default behavior
        // of focusing one of them.
        guard !flag else { return true }
        
        // No visible windows, open a new one.
        terminalManager.newWindow()
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
            // When opening a directory, create a new tab in the main window with that as the working directory.
            // If no windows exist, a new one will be created.
            config.workingDirectory = filename
            terminalManager.newTab(withBaseConfig: config)
        } else {
            // When opening a file, open a new window with that file as the command,
            // and its parent directory as the working directory.
            config.command = filename
            config.workingDirectory = (filename as NSString).deletingLastPathComponent
            terminalManager.newWindow(withBaseConfig: config)
        }

        return true
    }
    
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }
    
    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    private func syncMenuShortcuts() {
        guard ghostty.readiness == .ready else { return }
        
        syncMenuShortcut(action: "open_config", menuItem: self.menuOpenConfig)
        syncMenuShortcut(action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(action: "quit", menuItem: self.menuQuit)
        
        syncMenuShortcut(action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(action: "close_all_windows", menuItem: self.menuCloseAllWindows)
        syncMenuShortcut(action: "new_split:right", menuItem: self.menuSplitRight)
        syncMenuShortcut(action: "new_split:down", menuItem: self.menuSplitDown)
        
        syncMenuShortcut(action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(action: "paste_from_clipboard", menuItem: self.menuPaste)
        syncMenuShortcut(action: "select_all", menuItem: self.menuSelectAll)
        
        syncMenuShortcut(action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(action: "goto_split:top", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(action: "goto_split:bottom", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        syncMenuShortcut(action: "resize_split:up,10", menuItem: self.menuMoveSplitDividerUp)
        syncMenuShortcut(action: "resize_split:down,10", menuItem: self.menuMoveSplitDividerDown)
        syncMenuShortcut(action: "resize_split:right,10", menuItem: self.menuMoveSplitDividerRight)
        syncMenuShortcut(action: "resize_split:left,10", menuItem: self.menuMoveSplitDividerLeft)
        syncMenuShortcut(action: "equalize_splits", menuItem: self.menuEqualizeSplits)

        syncMenuShortcut(action: "increase_font_size:1", menuItem: self.menuIncreaseFontSize)
        syncMenuShortcut(action: "decrease_font_size:1", menuItem: self.menuDecreaseFontSize)
        syncMenuShortcut(action: "reset_font_size", menuItem: self.menuResetFontSize)
        syncMenuShortcut(action: "inspector:toggle", menuItem: self.menuTerminalInspector)
        
        // This menu item is NOT synced with the configuration because it disables macOS
        // global fullscreen keyboard shortcut. The shortcut in the Ghostty config will continue
        // to work but it won't be reflected in the menu item.
        //
        // syncMenuShortcut(action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)

        // Dock menu
        reloadDockMenu()
    }
    
    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    private func syncMenuShortcut(action: String, menuItem: NSMenuItem?) {
        guard let menu = menuItem else { return }
        guard let equiv = ghostty.config.keyEquivalent(for: action) else {
            // No shortcut, clear the menu item
            menu.keyEquivalent = ""
            menu.keyEquivalentModifierMask = []
            return
        }
        
        menu.keyEquivalent = equiv.key
        menu.keyEquivalentModifierMask = equiv.modifiers
    }
    
    private func focusedSurface() -> ghostty_surface_t? {
        return terminalManager.focusedSurface?.surface
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
        for c in terminalManager.windows {
            if let v = c.controller.surfaceTree?.findUUID(uuid: uuid) {
                return v
            }
        }
        
        return nil
    }
    
    func configDidReload(_ state: Ghostty.App) {
        // Depending on the "window-save-state" setting we have to set the NSQuitAlwaysKeepsWindows
        // configuration. This is the only way to carefully control whether macOS invokes the
        // state restoration system.
        switch (ghostty.config.windowSaveState) {
        case "never": UserDefaults.standard.setValue(false, forKey: "NSQuitAlwaysKeepsWindows")
        case "always": UserDefaults.standard.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        case "default": fallthrough
        default: UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
        }
        
        // Config could change keybindings, so update everything that depends on that
        syncMenuShortcuts()
        terminalManager.relabelAllTabs()
        
        // Config could change window appearance. We wrap this in an async queue because when
        // this is called as part of application launch it can deadlock with an internal
        // AppKit mutex on the appearance.
        DispatchQueue.main.async { self.syncAppearance() }
        
        // Update all of our windows
        terminalManager.windows.forEach { window in
            window.controller.configDidReload()
        }
        
        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = state.config.errors
        if (c.errors.count > 0) {
            if (c.window == nil || !c.window!.isVisible) {
                c.showWindow(self)
            }
        }
    }
    
    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance() {
        guard let theme = ghostty.config.windowTheme else { return }
        switch (theme) {
        case "dark":
            let appearance = NSAppearance(named: .darkAqua)
            NSApplication.shared.appearance = appearance
            
        case "light":
            let appearance = NSAppearance(named: .aqua)
            NSApplication.shared.appearance = appearance
            
        case "auto":
            let color = OSColor(ghostty.config.backgroundColor)
            let appearance = NSAppearance(named: color.isLightColor ? .aqua : .darkAqua)
            NSApplication.shared.appearance = appearance
        
        default:
            NSApplication.shared.appearance = nil
        }
    }
    
    //MARK: - Dock Menu
    
    private func reloadDockMenu() {
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")
        
        dockMenu.removeAllItems()
        dockMenu.addItem(newWindow)
        dockMenu.addItem(newTab)
    }
    
    //MARK: - IB Actions
    
    @IBAction func openConfig(_ sender: Any?) {
        ghostty.openConfig()
    }
    
    @IBAction func reloadConfig(_ sender: Any?) {
        ghostty.reloadConfig()
    }
    
    @IBAction func newWindow(_ sender: Any?) {
        terminalManager.newWindow()
        
        // We also activate our app so that it becomes front. This may be
        // necessary for the dock menu.
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func newTab(_ sender: Any?) {
        terminalManager.newTab()
        
        // We also activate our app so that it becomes front. This may be
        // necessary for the dock menu.
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func closeAllWindows(_ sender: Any?) {
        terminalManager.closeAllWindows()
        AboutController.shared.hide()
    }
    
    @IBAction func showAbout(_ sender: Any?) {
        AboutController.shared.show()
    }
    
    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://github.com/ghostty-org/ghostty") else { return }
        NSWorkspace.shared.open(url)
    }
}
