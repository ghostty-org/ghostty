import SwiftUI
import UserNotifications
import GhosttyKit

protocol GhosttyAppStateDelegate: AnyObject {
    /// Called when the configuration did finish reloading.
    func configDidReload(_ state: Ghostty.AppState)
}

extension Ghostty {
    enum AppReadiness {
        case loading, error, ready
    }

    enum FontSizeModification {
        case increase(Int)
        case decrease(Int)
        case reset
    }

    struct Info {
        var mode: ghostty_build_mode_e
        var version: String
    }

    /// The AppState is the global state that is associated with the Swift app. This handles initially
    /// initializing Ghostty, loading the configuration, etc.
    class AppState: ObservableObject {
        /// The readiness value of the state.
        @Published var readiness: AppReadiness = .loading

        /// Optional delegate
        weak var delegate: GhosttyAppStateDelegate?

        /// The ghostty global configuration. This should only be changed when it is definitely
        /// safe to change. It is definite safe to change only when the embedded app runtime
        /// in Ghostty says so (usually, only in a reload configuration callback).
        @Published var config: ghostty_config_t? = nil {
            didSet {
                // Free the old value whenever we change
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }

        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        @Published var app: ghostty_app_t? = nil {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// True if we should quit when the last window is closed.
        var shouldQuitAfterLastWindowClosed: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "quit-after-last-window-closed"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
        }

        /// True if we need to confirm before quitting.
        var needsConfirmQuit: Bool {
            guard let app = app else { return false }
            return ghostty_app_needs_confirm_quit(app)
        }

        /// Build information
        var info: Info {
            let raw = ghostty_info()
            let version = NSString(
                bytes: raw.version,
                length: Int(raw.version_len),
                encoding: NSUTF8StringEncoding
            ) ?? "unknown"

            return Info(mode: raw.build_mode, version: String(version))
        }

        /// True if we want to render window decorations
        var windowDecorations: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "window-decoration"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
        }
        
        /// The window theme as a string.
        var windowTheme: String? {
            guard let config = self.config else { return nil }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-theme"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard let ptr = v else { return nil }
            return String(cString: ptr)
        }
        
        /// Whether to resize windows in discrete steps or use "fluid" resizing
        var windowStepResize: Bool {
            guard let config = self.config else { return true }
            var v = false
            let key = "window-step-resize"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }
        
        /// Whether to open new windows in fullscreen.
        var windowFullscreen: Bool {
            guard let config = self.config else { return true }
            var v = false
            let key = "fullscreen"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        /// The background opacity.
        var backgroundOpacity: Double {
            guard let config = self.config else { return 1 }
            var v: Double = 1
            let key = "background-opacity"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
        }
        
        init() {
            // Initialize ghostty global state. This happens once per process.
            guard ghostty_init() == GHOSTTY_SUCCESS else {
                AppDelegate.logger.critical("ghostty_init failed")
                readiness = .error
                return
            }

            // Initialize the global configuration.
            guard let cfg = Self.loadConfig() else {
                readiness = .error
                return
            }
            self.config = cfg;

            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: false,
                wakeup_cb: { userdata in AppState.wakeup(userdata) },
                reload_config_cb: { userdata in AppState.reloadConfig(userdata) },
                set_title_cb: { userdata, title in AppState.setTitle(userdata, title: title) },
                set_mouse_shape_cb: { userdata, shape in AppState.setMouseShape(userdata, shape: shape) },
                set_mouse_visibility_cb: { userdata, visible in AppState.setMouseVisibility(userdata, visible: visible) },
                read_clipboard_cb: { userdata, loc, state in AppState.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in AppState.confirmReadClipboard(userdata, string: str, state: state, request: request ) },
                write_clipboard_cb: { userdata, str, loc, confirm in AppState.writeClipboard(userdata, string: str, location: loc, confirm: confirm) },
                new_split_cb: { userdata, direction, surfaceConfig in AppState.newSplit(userdata, direction: direction, config: surfaceConfig) },
                new_tab_cb: { userdata, surfaceConfig in AppState.newTab(userdata, config: surfaceConfig) },
                new_window_cb: { userdata, surfaceConfig in AppState.newWindow(userdata, config: surfaceConfig) },
                control_inspector_cb: { userdata, mode in AppState.controlInspector(userdata, mode: mode) },
                close_surface_cb: { userdata, processAlive in AppState.closeSurface(userdata, processAlive: processAlive) },
                focus_split_cb: { userdata, direction in AppState.focusSplit(userdata, direction: direction) },
                resize_split_cb: { userdata, direction, amount in
                    AppState.resizeSplit(userdata, direction: direction, amount: amount) },
                equalize_splits_cb: { userdata in
                    AppState.equalizeSplits(userdata) },
                toggle_split_zoom_cb: { userdata in AppState.toggleSplitZoom(userdata) },
                goto_tab_cb: { userdata, n in AppState.gotoTab(userdata, n: n) },
                toggle_fullscreen_cb: { userdata, nonNativeFullscreen in AppState.toggleFullscreen(userdata, nonNativeFullscreen: nonNativeFullscreen) },
                set_initial_window_size_cb: { userdata, width, height in AppState.setInitialWindowSize(userdata, width: width, height: height) },
                render_inspector_cb: { userdata in AppState.renderInspector(userdata) },
                set_cell_size_cb: { userdata, width, height in AppState.setCellSize(userdata, width: width, height: height) },
                show_desktop_notification_cb: { userdata, title, body in
                    AppState.showUserNotification(userdata, title: title, body: body)
                }
            )

            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
                AppDelegate.logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app

            // Subscribe to notifications for keyboard layout change so that we can update Ghostty.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)

            self.readiness = .ready
        }

        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            self.config = nil

            // Remove our observer
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
        }

        /// Initializes a new configuration and loads all the values.
        static func loadConfig() -> ghostty_config_t? {
            // Initialize the global configuration.
            guard let cfg = ghostty_config_new() else {
                AppDelegate.logger.critical("ghostty_config_new failed")
                return nil
            }

            // Load our configuration files from the home directory.
            ghostty_config_load_default_files(cfg);
            ghostty_config_load_cli_args(cfg);
            ghostty_config_load_recursive_files(cfg);

            // TODO: we'd probably do some config loading here... for now we'd
            // have to do this synchronously. When we support config updating we can do
            // this async and update later.

            // Finalize will make our defaults available.
            ghostty_config_finalize(cfg)

            // Log any configuration errors. These will be automatically shown in a
            // pop-up window too.
            let errCount = ghostty_config_errors_count(cfg)
            if errCount > 0 {
                AppDelegate.logger.warning("config error: \(errCount) configuration errors on reload")
                var errors: [String] = [];
                for i in 0..<errCount {
                    let err = ghostty_config_get_error(cfg, UInt32(i))
                    let message = String(cString: err.message)
                    errors.append(message)
                    AppDelegate.logger.warning("config error: \(message)")
                }
            }

            return cfg
        }

        /// Returns the configuration errors (if any).
        func configErrors() -> [String] {
            guard let cfg = self.config else { return [] }

            var errors: [String] = [];
            let errCount = ghostty_config_errors_count(cfg)
            for i in 0..<errCount {
                let err = ghostty_config_get_error(cfg, UInt32(i))
                let message = String(cString: err.message)
                errors.append(message)
            }

            return errors
        }

        func appTick() {
            guard let app = self.app else { return }

            // Tick our app, which lets us know if we want to quit
            let exit = ghostty_app_tick(app)
            if (!exit) { return }

            // We want to quit, start that process
            NSApplication.shared.terminate(nil)
        }

        func reloadConfig() {
            guard let app = self.app else { return }
            ghostty_app_reload_config(app)
        }

        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }

        func newTab(surface: ghostty_surface_t) {
            let action = "new_tab"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        func newWindow(surface: ghostty_surface_t) {
            let action = "new_window"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        func split(surface: ghostty_surface_t, direction: ghostty_split_direction_e) {
            ghostty_surface_split(surface, direction)
        }

        func splitMoveFocus(surface: ghostty_surface_t, direction: SplitFocusDirection) {
            ghostty_surface_split_focus(surface, direction.toNative())
        }

        func splitResize(surface: ghostty_surface_t, direction: SplitResizeDirection, amount: UInt16) {
            ghostty_surface_split_resize(surface, direction.toNative(), amount)
        }

        func splitEqualize(surface: ghostty_surface_t) {
            ghostty_surface_split_equalize(surface)
        }

        func splitToggleZoom(surface: ghostty_surface_t) {
            let action = "toggle_split_zoom"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }
        
        func toggleFullscreen(surface: ghostty_surface_t) {
            let action = "toggle_fullscreen"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        func changeFontSize(surface: ghostty_surface_t, _ change: FontSizeModification) {
            let action: String
            switch change {
            case .increase(let amount):
                action = "increase_font_size:\(amount)"
            case .decrease(let amount):
                action = "decrease_font_size:\(amount)"
            case .reset:
                action = "reset_font_size"
            }
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }
        
        func toggleTerminalInspector(surface: ghostty_surface_t) {
            let action = "inspector:toggle"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        // Called when the selected keyboard changes. We have to notify Ghostty so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        // MARK: Ghostty Callbacks

        static func newSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_direction_e, config: ghostty_surface_config_s) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.ghosttyNewSplit, object: surface, userInfo: [
                "direction": direction,
                Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: config),
            ])
        }

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.ghosttyCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }

        static func focusSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_focus_direction_e) {
            let surface = self.surfaceUserdata(from: userdata)
            guard let splitDirection = SplitFocusDirection.from(direction: direction) else { return }
            NotificationCenter.default.post(
                name: Notification.ghosttyFocusSplit,
                object: surface,
                userInfo: [
                    Notification.SplitDirectionKey: splitDirection,
                ]
            )
        }

        static func resizeSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_resize_direction_e, amount: UInt16) {
            let surface = self.surfaceUserdata(from: userdata)
            guard let resizeDirection = SplitResizeDirection.from(direction: direction) else { return }
            NotificationCenter.default.post(
                name: Notification.didResizeSplit,
                object: surface,
                userInfo: [
                    Notification.ResizeSplitDirectionKey: resizeDirection,
                    Notification.ResizeSplitAmountKey: amount,
                ]
            )
        }

        static func equalizeSplits(_ userdata: UnsafeMutableRawPointer?) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.didEqualizeSplits, object: surface)
        }

        static func toggleSplitZoom(_ userdata: UnsafeMutableRawPointer?) {
            let surface = self.surfaceUserdata(from: userdata)

            NotificationCenter.default.post(
                name: Notification.didToggleSplitZoom,
                object: surface
            )
        }

        static func gotoTab(_ userdata: UnsafeMutableRawPointer?, n: Int32) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(
                name: Notification.ghosttyGotoTab,
                object: surface,
                userInfo: [
                    Notification.GotoTabKey: n,
                ]
            )
        }

        static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
            // If we don't even have a surface, something went terrible wrong so we have
            // to leak "state".
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }
            
            // We only support the standard clipboard
            if (location != GHOSTTY_CLIPBOARD_STANDARD) {
                return completeClipboardRequest(surface, data: "", state: state)
            }
            
            // Get our string
            let str = NSPasteboard.general.string(forType: .string) ?? ""
            completeClipboardRequest(surface, data: str, state: state)
        }
        
        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            let surface = self.surfaceUserdata(from: userdata)
            guard let valueStr = String(cString: string!, encoding: .utf8) else { return }
            guard let request = Ghostty.ClipboardRequest.from(request: request) else { return }
            NotificationCenter.default.post(
                name: Notification.confirmClipboard,
                object: surface,
                userInfo: [
                    Notification.ConfirmClipboardStrKey: valueStr,
                    Notification.ConfirmClipboardStateKey: state as Any,
                    Notification.ConfirmClipboardRequestKey: request,
                ]
            )
        }
        
        static func completeClipboardRequest(
            _ surface: ghostty_surface_t,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            data.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
            }
        }

        static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, string: UnsafePointer<CChar>?, location: ghostty_clipboard_e, confirm: Bool) {
            let surface = self.surfaceUserdata(from: userdata)

            // We only support the standard clipboard
            if (location != GHOSTTY_CLIPBOARD_STANDARD) { return }

            guard let valueStr = String(cString: string!, encoding: .utf8) else { return }
            if !confirm {
                let pb = NSPasteboard.general
                pb.declareTypes([.string], owner: nil)
                pb.setString(valueStr, forType: .string)
                return
            }
            
            NotificationCenter.default.post(
                name: Notification.confirmClipboard,
                object: surface,
                userInfo: [
                    Notification.ConfirmClipboardStrKey: valueStr,
                    Notification.ConfirmClipboardRequestKey: Ghostty.ClipboardRequest.osc_52_write,
                ]
            )
        }

        static func reloadConfig(_ userdata: UnsafeMutableRawPointer?) -> ghostty_config_t? {
            guard let newConfig = Self.loadConfig() else {
                AppDelegate.logger.warning("failed to reload configuration")
                return nil
            }

            // Assign the new config. This will automatically free the old config.
            // It is safe to free the old config from within this function call.
            let state = Unmanaged<AppState>.fromOpaque(userdata!).takeUnretainedValue()
            state.config = newConfig

            // If we have a delegate, notify.
            if let delegate = state.delegate {
                delegate.configDidReload(state)
            }

            return newConfig
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<AppState>.fromOpaque(userdata!).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread. There is probably some improvements we can make
            // to coalesce multiple ticks but I don't think it matters from a performance
            // standpoint since we don't do this much.
            DispatchQueue.main.async { state.appTick() }
        }
        
        static func renderInspector(_ userdata: UnsafeMutableRawPointer?) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(
                name: Notification.inspectorNeedsDisplay,
                object: surface
            )
        }

        static func setTitle(_ userdata: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let titleStr = String(cString: title!, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                surfaceView.title = titleStr
            }
        }

        static func setMouseShape(_ userdata: UnsafeMutableRawPointer?, shape: ghostty_mouse_shape_e) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            surfaceView.setCursorShape(shape)
        }

        static func setMouseVisibility(_ userdata: UnsafeMutableRawPointer?, visible: Bool) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            surfaceView.setCursorVisibility(visible)
        }

        static func toggleFullscreen(_ userdata: UnsafeMutableRawPointer?, nonNativeFullscreen: ghostty_non_native_fullscreen_e) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(
                name: Notification.ghosttyToggleFullscreen,
                object: surface,
                userInfo: [
                    Notification.NonNativeFullscreenKey: nonNativeFullscreen,
                ]
            )
        }
        
        static func setInitialWindowSize(_ userdata: UnsafeMutableRawPointer?, width: UInt32, height: UInt32) {
            // We need a window to set the frame
            let surfaceView = self.surfaceUserdata(from: userdata)
            surfaceView.initialSize = NSMakeSize(Double(width), Double(height))
        }

        static func setCellSize(_ userdata: UnsafeMutableRawPointer?, width: UInt32, height: UInt32) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            let backingSize = NSSize(width: Double(width), height: Double(height))
            surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
        }

        static func showUserNotification(_ userdata: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?, body: UnsafePointer<CChar>?) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let title = String(cString: title!, encoding: .utf8) else { return }
            guard let body = String(cString: body!, encoding: .utf8) else { return }

            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error = error {
                    AppDelegate.logger.error("Error while requesting notification authorization: \(error)")
                }
            }

            center.getNotificationSettings() { settings in
                guard settings.authorizationStatus == .authorized else { return }
                surfaceView.showUserNotification(title: title, body: body)
            }
        }

        /// Handle a received user notification. This is called when a user notification is clicked or dismissed by the user
        func handleUserNotification(response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo
            guard let address = userInfo["address"] as? Int else { return }
            guard let userdata = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let surface = Ghostty.AppState.surfaceUserdata(from: userdata)

            switch (response.actionIdentifier) {
            case UNNotificationDefaultActionIdentifier, Ghostty.userNotificationActionShow:
                // The user clicked on a notification
                surface.handleUserNotification(notification: response.notification, focus: true)
            case UNNotificationDismissActionIdentifier:
                // The user dismissed the notification
                surface.handleUserNotification(notification: response.notification, focus: false)
            default:
                break
            }
        }

        /// Determine if a given notification should be presented to the user when Ghostty is running in the foreground.
        func shouldPresentNotification(notification: UNNotification) -> Bool {
            let userInfo = notification.request.content.userInfo
            guard let address = userInfo["address"] as? Int else { return false }
            guard let userdata = UnsafeMutableRawPointer(bitPattern: address) else { return false }
            let surface = Ghostty.AppState.surfaceUserdata(from: userdata)

            guard let window = surface.window else { return false }
            return !window.isKeyWindow || !surface.focused
        }

        static func newTab(_ userdata: UnsafeMutableRawPointer?, config: ghostty_surface_config_s) {
            let surface = self.surfaceUserdata(from: userdata)
            
            guard let appState = self.appState(fromView: surface) else { return }
            guard appState.windowDecorations else {
                let alert = NSAlert()
                alert.messageText = "Tabs are disabled"
                alert.informativeText = "Enable window decorations to use tabs"
                alert.addButton(withTitle: "OK")
                alert.alertStyle = .warning
                _ = alert.runModal()
                return
            }
            
            NotificationCenter.default.post(
                name: Notification.ghosttyNewTab,
                object: surface,
                userInfo: [
                    Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: config),
                ]
            )
        }

        static func newWindow(_ userdata: UnsafeMutableRawPointer?, config: ghostty_surface_config_s) {
            let surface = self.surfaceUserdata(from: userdata)

            NotificationCenter.default.post(
                name: Notification.ghosttyNewWindow,
                object: surface,
                userInfo: [
                    Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: config),
                ]
            )
        }
        
        static func controlInspector(_ userdata: UnsafeMutableRawPointer?, mode: ghostty_inspector_mode_e) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.didControlInspector, object: surface, userInfo: [
                "mode": mode,
            ])
        }

        /// Returns the GhosttyState from the given userdata value.
        static private func appState(fromView view: SurfaceView) -> AppState? {
            guard let surface = view.surface else { return nil }
            guard let app = ghostty_surface_app(surface) else { return nil }
            guard let app_ud = ghostty_app_userdata(app) else { return nil }
            return Unmanaged<AppState>.fromOpaque(app_ud).takeUnretainedValue()
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }
    }
}
