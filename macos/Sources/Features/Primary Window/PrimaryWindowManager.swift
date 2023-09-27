import Cocoa
import Combine
import GhosttyKit
import SwiftUI

// PrimaryWindowManager manages the windows and tabs in the primary window
// of the application. It keeps references to windows and cleans them up when
// they're cloned.
//
// If we ever have multiple tabbed window types we can make this generic but
// right now only our primary window is ever duplicated or tabbed so we're not
// doing that.
//
// It is based on the patterns presented in this blog post:
// https://christiantietze.de/posts/2019/07/nswindow-tabbing-multiple-nswindowcontroller/
class PrimaryWindowManager {
    struct ManagedWindow {
        let windowController: NSWindowController
        let window: NSWindow
        let closePublisher: AnyCancellable
    }
    
    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
    /// Returns the main window of the managed window stack.
    /// Falls back the first element if no window is main. Note that this would
    /// likely be an internal inconsistency we gracefully handle here.
    var mainWindow: NSWindow? {
        let mainManagedWindow = managedWindows
            .first { $0.window.isMainWindow }

        return (mainManagedWindow ?? managedWindows.first)
            .map { $0.window }
    }

    private var ghostty: Ghostty.AppState
    private var managedWindows: [ManagedWindow] = []
    
    init(ghostty: Ghostty.AppState) {
        self.ghostty = ghostty
        
        // Register self as observer for the NewTab/NewWindow notifications that
        // are triggered via callback from Zig code.
        let center = NotificationCenter.default;
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onNewWindow),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
    }
    
    deinit {
        // Clean up the observers.
        let center = NotificationCenter.default;
        center.removeObserver(
            self,
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.removeObserver(
            self,
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
    }
    
    /// Add the initial window for the application. This should only be called once from the AppDelegate.
    func addInitialWindow() {
        guard let controller = createWindowController() else { return }
        controller.showWindow(self)
        let result = addManagedWindow(windowController: controller)
        if result == nil {
            preconditionFailure("Failed to create initial window")
        }
    }
    
    func newWindow() {
        if let window = mainWindow as? PrimaryWindow {
            // If we already have a window, we go through Zig core code, which calls back into Swift.
            self.triggerNewWindow(withParent: window)
        } else {
            self.addNewWindow()
        }
    }
    
    func triggerNewWindow(withParent window: PrimaryWindow) {
        guard let surface = window.focusedSurfaceWrapper.surface else { return }
        ghostty.newWindow(surface: surface)
    }
    
    func addNewWindow(withBaseConfig config: ghostty_surface_config_s? = nil) {
        guard let controller = createWindowController(withBaseConfig: config) else { return }
        controller.showWindow(self)
        guard let newWindow = addManagedWindow(windowController: controller)?.window else { return }
        newWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc private func onNewWindow(notification: SwiftUI.Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? ghostty_surface_config_s
        
        self.addNewWindow(withBaseConfig: config)
    }
    
    // triggerNewTab tells the Zig core code to create a new tab, which then calls
    // back into Swift code.
    func triggerNewTab(for window: PrimaryWindow) {
        guard let surface = window.focusedSurfaceWrapper.surface else { return }
        ghostty.newTab(surface: surface)
    }
    
    func newTab() {
        if let window = mainWindow as? PrimaryWindow {
            self.triggerNewTab(for: window)
        } else {
            self.addNewWindow()
        }
    }

    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }
        
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? ghostty_surface_config_s
        
        self.addNewTab(to: window, withBaseConfig: config)
    }
    
    private func addNewTab(to window: NSWindow, withBaseConfig config: ghostty_surface_config_s? = nil) {
        guard let controller = createWindowController(withBaseConfig: config, cascade: false) else { return }
        guard let newWindow = addManagedWindow(windowController: controller)?.window else { return  }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func createWindowController(withBaseConfig config: ghostty_surface_config_s? = nil, cascade: Bool = true) -> PrimaryWindowController? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        
        let window = PrimaryWindow.create(ghostty: ghostty, appDelegate: appDelegate, baseConfig: config)
        if (cascade) {
            Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
        }
        
        let controller = PrimaryWindowController(window: window)
        controller.windowManager = self
        return controller
    }

    private func addManagedWindow(windowController: PrimaryWindowController) -> ManagedWindow? {
        guard let window = windowController.window else { return nil }

        let pubClose = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { notification in
                guard let window = notification.object as? NSWindow else { return }
                self.removeWindow(window: window)
            }
        
        let managed = ManagedWindow(windowController: windowController, window: window, closePublisher: pubClose)
        managedWindows.append(managed)
        window.delegate = windowController

        return managed
    }
    
    private func removeWindow(window: NSWindow) {
        self.managedWindows.removeAll(where: { $0.window === window })
        
        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    /// Update the accessory view of the first 9 tabs. This is called when the
    /// key window changes and when a window is closed.
    func indexTabs() {
        if let windows = self.mainWindow?.tabbedWindows {
            for (index, window) in windows.enumerated().prefix(9) {
                let string = " ⌘\(index + 1) "
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.labelFont(ofSize: 0),
                    .foregroundColor: window.isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]
                let attributedString = NSAttributedString(string: string, attributes: attributes)
                let text = NSTextField(labelWithAttributedString: attributedString)
                window.tab.accessoryView = text
            }
        }
    }
}
