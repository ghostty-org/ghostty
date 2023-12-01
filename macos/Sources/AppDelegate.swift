import AppKit
import UserNotifications
import OSLog
import GhosttyKit

class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, GhosttyAppStateDelegate {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )
    
    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Ghostty config.
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?
    
    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitHorizontal: NSMenuItem?
    @IBOutlet private var menuSplitVertical: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseWindow: NSMenuItem?
    
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?

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
    
    /// The ghostty global state. Only one per process.
    private let ghostty: Ghostty.AppState = Ghostty.AppState()
    
    /// Manages our terminal windows.
    let terminalManager: TerminalManager
    
    override init() {
        self.terminalManager = TerminalManager(ghostty)
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
        
        // Let's launch our first window.
        // TODO: we should detect if we restored windows and if so not launch a new window.
        terminalManager.newWindow()
        
        // Initial config loading
        configDidReload(ghostty)
        
        // Register our service provider. This must happen after everything
        // else is initialized.
        NSApp.servicesProvider = ServiceProvider()

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return ghostty.shouldQuitAfterLastWindowClosed
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
        guard isDirectory.boolValue else {
            let alert = NSAlert()
            alert.messageText = "Dropped File is Not a Directory"
            alert.informativeText = "Ghostty can currently only open directory paths."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            _ = alert.runModal()
            return false
        }
        
        // Build our config
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = filename
        
        // Add a new tab or create a new window
        terminalManager.newTab(withBaseConfig: config)
        return true
    }
    
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }
    
    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    private func syncMenuShortcuts() {
        guard ghostty.config != nil else { return }
        
        syncMenuShortcut(action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(action: "quit", menuItem: self.menuQuit)
        
        syncMenuShortcut(action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(action: "new_split:right", menuItem: self.menuSplitHorizontal)
        syncMenuShortcut(action: "new_split:down", menuItem: self.menuSplitVertical)
        
        syncMenuShortcut(action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(action: "paste_from_clipboard", menuItem: self.menuPaste)
        
        syncMenuShortcut(action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)
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

        // Dock menu
        reloadDockMenu()
    }
    
    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    private func syncMenuShortcut(action: String, menuItem: NSMenuItem?) {
        guard let cfg = ghostty.config else { return }
        guard let menu = menuItem else { return }
        
        let trigger = ghostty_config_trigger(cfg, action, UInt(action.count))
        guard let equiv = Ghostty.keyEquivalent(key: trigger.key) else {
            // No shortcut, clear the menu item
            menu.keyEquivalent = ""
            menu.keyEquivalentModifierMask = []
            return
        }
        
        menu.keyEquivalent = equiv
        menu.keyEquivalentModifierMask = Ghostty.eventModifierFlags(mods: trigger.mods)
    }
    
    private func focusedSurface() -> ghostty_surface_t? {
        return terminalManager.focusedSurface?.surface
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

    //MARK: - GhosttyAppStateDelegate
    
    func configDidReload(_ state: Ghostty.AppState) {
        // Config could change keybindings, so update everything that depends on that
        syncMenuShortcuts()
        terminalManager.relabelAllTabs()
        
        // Config could change window appearance
        syncAppearance()
        
        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = state.configErrors()
        if (c.errors.count > 0) {
            if (c.window == nil || !c.window!.isVisible) {
                c.showWindow(self)
            }
        }
    }
    
    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance() {
        guard let theme = ghostty.windowTheme else { return }
        switch (theme) {
        case "dark":
            let appearance = NSAppearance(named: .darkAqua)
            NSApplication.shared.appearance = appearance
            
        case "light":
            let appearance = NSAppearance(named: .aqua)
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
    
    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://github.com/mitchellh/ghostty") else { return }
        NSWorkspace.shared.open(url)
    }
}
