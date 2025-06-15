import SwiftUI
import UserNotifications
import GhosttyKit

protocol GhosttyAppDelegate: AnyObject {
    #if os(macOS)
    /// Called when a callback needs access to a specific surface. This should return nil
    /// when the surface is no longer valid.
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView?
    #endif
}

extension Ghostty {
    // IMPORTANT: THIS IS NOT DONE.
    // This is a refactor/redo of Ghostty.AppState so that it supports both macOS and iOS
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Optional delegate
        weak var delegate: GhosttyAppDelegate?

        /// The readiness value of the state.
        @Published var readiness: Readiness = .loading

        /// The global app configuration. This defines the app level configuration plus any behavior
        /// for new windows, tabs, etc. Note that when creating a new window, it may inherit some
        /// configuration (i.e. font size) from the previously focused window. This would override this.
        @Published private(set) var config: Config

        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        @Published var app: ghostty_app_t? = nil {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// True if we need to confirm before quitting.
        var needsConfirmQuit: Bool {
            guard let app = app else { return false }
            return ghostty_app_needs_confirm_quit(app)
        }

        init() {
            // Initialize ghostty global state. This happens once per process.
            if ghostty_init() != GHOSTTY_SUCCESS {
                logger.critical("ghostty_init failed, weird things may happen")
                readiness = .error
            }

            // Initialize the global configuration.
            self.config = Config()
            if self.config.config == nil {
                readiness = .error
                return
            }

            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in App.confirmReadClipboard(userdata, string: str, state: state, request: request ) },
                write_clipboard_cb: { userdata, str, loc, confirm in App.writeClipboard(userdata, string: str, location: loc, confirm: confirm) },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app

#if os(macOS)
            // Set our initial focus state
            ghostty_app_set_focus(app, NSApp.isActive)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(notification:)),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive(notification:)),
                name: NSApplication.didResignActiveNotification,
                object: nil)
#endif

            self.readiness = .ready
        }

        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil

#if os(macOS)
            NotificationCenter.default.removeObserver(self)
#endif
        }

        // MARK: App Operations

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        func openConfig() {
            guard let app = self.app else { return }
            ghostty_app_open_config(app)
        }

        /// Reload the configuration.
        func reloadConfig(soft: Bool = false) {
            guard let app = self.app else { return }

            // Soft updates just call with our existing config
            if (soft) {
                ghostty_app_update_config(app, config.config!)
                return
            }

            // Hard or full updates have to reload the full configuration
            let newConfig = Config()
            guard newConfig.loaded else {
                Ghostty.logger.warning("failed to reload configuration")
                return
            }

            ghostty_app_update_config(app, newConfig.config!)

            // We can only set our config after updating it so that we don't free
            // memory that may still be in use
            self.config = newConfig
        }

        func reloadConfig(surface: ghostty_surface_t, soft: Bool = false) {
            // Soft updates just call with our existing config
            if (soft) {
                ghostty_surface_update_config(surface, config.config!)
                return
            }

            // Hard or full updates have to reload the full configuration.
            // NOTE: We never set this on self.config because this is a surface-only
            // config. We free it after the call.
            let newConfig = Config()
            guard newConfig.loaded else {
                Ghostty.logger.warning("failed to reload configuration")
                return
            }

            ghostty_surface_update_config(surface, newConfig.config!)
        }

        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }

        func newTab(surface: ghostty_surface_t) {
            let action = "new_tab"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                logger.warning("action failed action=\(action)")
            }
        }

        func newWindow(surface: ghostty_surface_t) {
            let action = "new_window"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                logger.warning("action failed action=\(action)")
            }
        }

        func split(surface: ghostty_surface_t, direction: ghostty_action_split_direction_e) {
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
                logger.warning("action failed action=\(action)")
            }
        }

        func toggleFullscreen(surface: ghostty_surface_t) {
            let action = "toggle_fullscreen"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                logger.warning("action failed action=\(action)")
            }
        }

        enum FontSizeModification {
            case increase(Int)
            case decrease(Int)
            case reset
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
                logger.warning("action failed action=\(action)")
            }
        }

        func toggleTerminalInspector(surface: ghostty_surface_t) {
            let action = "inspector:toggle"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                logger.warning("action failed action=\(action)")
            }
        }

        func resetTerminal(surface: ghostty_surface_t) {
            let action = "reset"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                logger.warning("action failed action=\(action)")
            }
        }

        #if os(iOS)
        // MARK: Ghostty Callbacks (iOS)

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {}
        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool { return false }
        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) {}

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {}

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            location: ghostty_clipboard_e,
            confirm: Bool
        ) {}

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {}
        #endif

        #if os(macOS)

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify Ghostty so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        // Called when the app becomes active.
        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }

        // Called when the app becomes inactive.
        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }


        // MARK: Ghostty Callbacks (macOS)

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.ghosttyCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }

        static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
            // If we don't even have a surface, something went terrible wrong so we have
            // to leak "state".
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.ghostty(location) else {
                return completeClipboardRequest(surface, data: "", state: state)
            }

            // Get our string
            let str = pasteboard.getOpinionatedStringContents() ?? ""
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


            guard let pasteboard = NSPasteboard.ghostty(location) else { return }
            guard let valueStr = String(cString: string!, encoding: .utf8) else { return }
            if !confirm {
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(valueStr, forType: .string)
                return
            }

            NotificationCenter.default.post(
                name: Notification.confirmClipboard,
                object: surface,
                userInfo: [
                    Notification.ConfirmClipboardStrKey: valueStr,
                    Notification.ConfirmClipboardRequestKey: Ghostty.ClipboardRequest.osc_52_write(pasteboard),
                ]
            )
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread. There is probably some improvements we can make
            // to coalesce multiple ticks but I don't think it matters from a performance
            // standpoint since we don't do this much.
            DispatchQueue.main.async { state.appTick() }
        }

        /// Determine if a given notification should be presented to the user when Ghostty is running in the foreground.
        func shouldPresentNotification(notification: UNNotification) -> Bool {
            let userInfo = notification.request.content.userInfo
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = delegate?.findSurface(forUUID: uuid),
                  let window = surface.window else { return false }
            return !window.isKeyWindow || !surface.focused
        }

        /// Returns the GhosttyState from the given userdata value.
        static private func appState(fromView view: SurfaceView) -> App? {
            guard let surface = view.surface else { return nil }
            guard let app = ghostty_surface_app(surface) else { return nil }
            guard let app_ud = ghostty_app_userdata(app) else { return nil }
            return Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }

        static private func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
            guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
        }

        // MARK: Actions (macOS)

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Make sure it a target we understand so all our action handlers can assert
            switch (target.tag) {
            case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
                break

            default:
                Ghostty.logger.warning("unknown action target=\(target.tag.rawValue)")
                return false
            }

            // Action dispatch
            switch (action.tag) {
            case GHOSTTY_ACTION_QUIT:
                quit(app)

            case GHOSTTY_ACTION_NEW_WINDOW:
                newWindow(app, target: target)

            case GHOSTTY_ACTION_NEW_TAB:
                newTab(app, target: target)

            case GHOSTTY_ACTION_NEW_SPLIT:
                newSplit(app, target: target, direction: action.action.new_split)

            case GHOSTTY_ACTION_CLOSE_TAB:
                closeTab(app, target: target)

            case GHOSTTY_ACTION_CLOSE_WINDOW:
                closeWindow(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
                toggleFullscreen(app, target: target, mode: action.action.toggle_fullscreen)

            case GHOSTTY_ACTION_MOVE_TAB:
                return moveTab(app, target: target, move: action.action.move_tab)

            case GHOSTTY_ACTION_GOTO_TAB:
                return gotoTab(app, target: target, tab: action.action.goto_tab)

            case GHOSTTY_ACTION_GOTO_SPLIT:
                return gotoSplit(app, target: target, direction: action.action.goto_split)

            case GHOSTTY_ACTION_RESIZE_SPLIT:
                resizeSplit(app, target: target, resize: action.action.resize_split)

            case GHOSTTY_ACTION_EQUALIZE_SPLITS:
                equalizeSplits(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
                toggleSplitZoom(app, target: target)

            case GHOSTTY_ACTION_INSPECTOR:
                controlInspector(app, target: target, mode: action.action.inspector)

            case GHOSTTY_ACTION_RENDER_INSPECTOR:
                renderInspector(app, target: target)

            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                showDesktopNotification(app, target: target, n: action.action.desktop_notification)

            case GHOSTTY_ACTION_SET_TITLE:
                setTitle(app, target: target, v: action.action.set_title)

            case GHOSTTY_ACTION_PROMPT_TITLE:
                return promptTitle(app, target: target)

            case GHOSTTY_ACTION_PWD:
                pwdChanged(app, target: target, v: action.action.pwd)

            case GHOSTTY_ACTION_OPEN_CONFIG:
                ghostty_config_open()

            case GHOSTTY_ACTION_FLOAT_WINDOW:
                toggleFloatWindow(app, target: target, mode: action.action.float_window)

            case GHOSTTY_ACTION_SECURE_INPUT:
                toggleSecureInput(app, target: target, mode: action.action.secure_input)

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                setMouseShape(app, target: target, shape: action.action.mouse_shape)

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                setMouseVisibility(app, target: target, v: action.action.mouse_visibility)

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                setMouseOverLink(app, target: target, v: action.action.mouse_over_link)

            case GHOSTTY_ACTION_INITIAL_SIZE:
                setInitialSize(app, target: target, v: action.action.initial_size)

            case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
                resetWindowSize(app, target: target)

            case GHOSTTY_ACTION_CELL_SIZE:
                setCellSize(app, target: target, v: action.action.cell_size)

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                rendererHealth(app, target: target, v: action.action.renderer_health)

            case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
                toggleCommandPalette(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
                toggleMaximize(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
                toggleQuickTerminal(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
                toggleVisibility(app, target: target)

            case GHOSTTY_ACTION_KEY_SEQUENCE:
                keySequence(app, target: target, v: action.action.key_sequence)

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                configChange(app, target: target, v: action.action.config_change)

            case GHOSTTY_ACTION_RELOAD_CONFIG:
                configReload(app, target: target, v: action.action.reload_config)

            case GHOSTTY_ACTION_COLOR_CHANGE:
                colorChange(app, target: target, change: action.action.color_change)

            case GHOSTTY_ACTION_RING_BELL:
                ringBell(app, target: target)

            case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
                checkForUpdates(app)

            case GHOSTTY_ACTION_UNDO:
                return undo(app, target: target)

            case GHOSTTY_ACTION_REDO:
                return redo(app, target: target)

            case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
                fallthrough
            case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
                fallthrough
            case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
                fallthrough
            case GHOSTTY_ACTION_PRESENT_TERMINAL:
                fallthrough
            case GHOSTTY_ACTION_SIZE_LIMIT:
                fallthrough
            case GHOSTTY_ACTION_QUIT_TIMER:
                Ghostty.logger.info("known but unimplemented action action=\(action.tag.rawValue)")
                return false
            default:
                Ghostty.logger.warning("unknown action action=\(action.tag.rawValue)")
                return false
            }

            // If we reached here then we assume performed since all unknown actions
            // are captured in the switch and return false.
            return true
        }

        private static func quit(_ app: ghostty_app_t) {
            // On iOS, applications do not terminate programmatically like they do
            // on macOS. On iOS, applications are only terminated when a user physically
            // closes the application (i.e. going to the home screen). If we request
            // exit on iOS we ignore it.
            #if os(iOS)
            logger.info("quit request received, ignoring on iOS")
            #endif

            #if os(macOS)
            // We want to quit, start that process
            NSApplication.shared.terminate(nil)
            #endif
        }

        private static func checkForUpdates(
            _ app: ghostty_app_t
        ) {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.checkForUpdates(nil)
            }
        }

        private static func undo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
            let undoManager: UndoManager?
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                undoManager = surfaceView.undoManager

            default:
                assertionFailure()
                return false
            }

            guard let undoManager, undoManager.canUndo else { return false }
            undoManager.undo()
            return true
        }

        private static func redo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
            let undoManager: UndoManager?
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                undoManager = surfaceView.undoManager

            default:
                assertionFailure()
                return false
            }

            guard let undoManager, undoManager.canRedo else { return false }
            undoManager.redo()
            return true
        }

        private static func newWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewWindow,
                    object: nil,
                    userInfo: [:]
                )

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewWindow,
                    object: surfaceView,
                    userInfo: [
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: ghostty_surface_inherited_config(surface)),
                    ]
                )


            default:
                assertionFailure()
            }
        }

        private static func newTab(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewTab,
                    object: nil,
                    userInfo: [:]
                )

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let appState = self.appState(fromView: surfaceView) else { return }
                guard appState.config.windowDecorations else {
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
                    object: surfaceView,
                    userInfo: [
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: ghostty_surface_inherited_config(surface)),
                    ]
                )


            default:
                assertionFailure()
            }
        }

        private static func newSplit(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            direction: ghostty_action_split_direction_e) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                // New split does nothing with an app target
                Ghostty.logger.warning("new split does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: Notification.ghosttyNewSplit,
                    object: surfaceView,
                    userInfo: [
                        "direction": direction,
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: ghostty_surface_inherited_config(surface)),
                    ]
                )


            default:
                assertionFailure()
            }
        }

        private static func closeTab(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("close tab does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: .ghosttyCloseTab,
                    object: surfaceView
                )


            default:
                assertionFailure()
            }
        }

        private static func closeWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("close window does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: .ghosttyCloseWindow,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleFullscreen(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode raw: ghostty_action_fullscreen_e) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle fullscreen does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let mode = FullscreenMode.from(ghostty: raw) else {
                    Ghostty.logger.warning("unknown fullscreen mode raw=\(raw.rawValue)")
                    return
                }
                NotificationCenter.default.post(
                    name: Notification.ghosttyToggleFullscreen,
                    object: surfaceView,
                    userInfo: [
                        Notification.FullscreenModeKey: mode,
                    ]
                )


            default:
                assertionFailure()
            }
        }

        private static func toggleCommandPalette(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle command palette does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyCommandPaletteDidToggle,
                    object: surfaceView
                )


            default:
                assertionFailure()
            }
        }

        private static func toggleMaximize(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle maximize does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyMaximizeDidToggle,
                    object: surfaceView
                )


            default:
                assertionFailure()
            }
        }

        private static func toggleVisibility(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.toggleVisibility(self)
        }

        private static func ringBell(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                // Technically we could still request app attention here but there
                // are no known cases where the bell is rang with an app target so
                // I think its better to warn.
                Ghostty.logger.warning("ring bell does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyBellDidRing,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func moveTab(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            move: ghostty_action_move_tab_s) -> Bool {
                switch (target.tag) {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("move tab does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // See gotoTab for notes on this check.
                    guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    NotificationCenter.default.post(
                        name: .ghosttyMoveTab,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyMoveTabKey: Action.MoveTab(c: move),
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func gotoTab(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            tab: ghostty_action_goto_tab_e) -> Bool {
                switch (target.tag) {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("goto tab does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // Similar to goto_split (see comment there) about our performability,
                    // we should make this more accurate later.
                    guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    NotificationCenter.default.post(
                        name: Notification.ghosttyGotoTab,
                        object: surfaceView,
                        userInfo: [
                            Notification.GotoTabKey: tab,
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func gotoSplit(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            direction: ghostty_action_goto_split_e) -> Bool {
                switch (target.tag) {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("goto split does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let controller = surfaceView.window?.windowController as? BaseTerminalController else { return false }

                    // For now, we return false if the window has no splits and we return
                    // true if the window has ANY splits. This isn't strictly correct because
                    // we should only be returning true if we actually performed the action,
                    // but this handles the most common case of caring about goto_split performability
                    // which is the no-split case.
                    guard controller.surfaceTree.isSplit else { return false }

                    NotificationCenter.default.post(
                        name: Notification.ghosttyFocusSplit,
                        object: surfaceView,
                        userInfo: [
                            Notification.SplitDirectionKey: SplitFocusDirection.from(direction: direction) as Any,
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func resizeSplit(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            resize: ghostty_action_resize_split_s) {
                switch (target.tag) {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("resize split does nothing with an app target")
                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    guard let resizeDirection = SplitResizeDirection.from(direction: resize.direction) else { return }
                    NotificationCenter.default.post(
                        name: Notification.didResizeSplit,
                        object: surfaceView,
                        userInfo: [
                            Notification.ResizeSplitDirectionKey: resizeDirection,
                            Notification.ResizeSplitAmountKey: resize.amount,
                        ]
                    )

                default:
                    assertionFailure()
                }
        }

        private static func equalizeSplits(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("equalize splits does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didEqualizeSplits,
                    object: surfaceView
                )


            default:
                assertionFailure()
            }
        }

        private static func toggleSplitZoom(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle split zoom does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didToggleSplitZoom,
                    object: surfaceView
                )


            default:
                assertionFailure()
            }
        }

        private static func controlInspector(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode: ghostty_action_inspector_e) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle split zoom does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didControlInspector,
                    object: surfaceView,
                    userInfo: ["mode": mode]
                )


            default:
                assertionFailure()
            }
        }

        private static func showDesktopNotification(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            n: ghostty_action_desktop_notification_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle split zoom does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: n.title!, encoding: .utf8) else { return }
                guard let body = String(cString: n.body!, encoding: .utf8) else { return }

                let center = UNUserNotificationCenter.current()
                center.requestAuthorization(options: [.alert, .sound]) { _, error in
                    if let error = error {
                        Ghostty.logger.error("Error while requesting notification authorization: \(error)")
                    }
                }

                center.getNotificationSettings() { settings in
                    guard settings.authorizationStatus == .authorized else { return }
                    surfaceView.showUserNotification(title: title, body: body)
                }


            default:
                assertionFailure()
            }
        }

        private static func toggleFloatWindow(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode mode_raw: ghostty_action_float_window_e
        ) {
            guard let mode = SetFloatWIndow.from(mode_raw) else { return }

            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle float window does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let window = surfaceView.window as? TerminalWindow else { return }

                switch (mode) {
                case .on:
                    window.level = .floating

                case .off:
                    window.level = .normal

                case .toggle:
                    window.level = window.level == .floating ? .normal : .floating
                }

                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.syncFloatOnTopMenu(window)
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleSecureInput(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode mode_raw: ghostty_action_secure_input_e
        ) {
            guard let mode = SetSecureInput.from(mode_raw) else { return }

            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
                appDelegate.setSecureInput(mode)

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let appState = self.appState(fromView: surfaceView) else { return }
                guard appState.config.autoSecureInput else { return }

                switch (mode) {
                case .on:
                    surfaceView.passwordInput = true

                case .off:
                    surfaceView.passwordInput = false

                case .toggle:
                    surfaceView.passwordInput = !surfaceView.passwordInput
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleQuickTerminal(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.toggleQuickTerminal(self)
        }

        private static func setTitle(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_set_title_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set title does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: v.title!, encoding: .utf8) else { return }
                surfaceView.setTitle(title)

            default:
                assertionFailure()
            }
        }

        private static func promptTitle(
            _ app: ghostty_app_t,
            target: ghostty_target_s) -> Bool {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set title prompt does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                surfaceView.promptTitle()

            default:
                assertionFailure()
            }

            return true
        }

        private static func pwdChanged(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_pwd_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("pwd change does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let pwd = String(cString: v.pwd!, encoding: .utf8) else { return }
                surfaceView.pwd = pwd

            default:
                assertionFailure()
            }
        }

        private static func setMouseShape(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            shape: ghostty_action_mouse_shape_e) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set mouse shapes nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.setCursorShape(shape)


            default:
                assertionFailure()
            }
        }

        private static func setMouseVisibility(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_mouse_visibility_e) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set mouse shapes nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                switch (v) {
                case GHOSTTY_MOUSE_VISIBLE:
                    surfaceView.setCursorVisibility(true)

                case GHOSTTY_MOUSE_HIDDEN:
                    surfaceView.setCursorVisibility(false)

                default:
                    return
                }


            default:
                assertionFailure()
            }
        }

        private static func setMouseOverLink(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_mouse_over_link_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard v.len > 0 else {
                    surfaceView.hoverUrl = nil
                    return
                }

                let buffer = Data(bytes: v.url!, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)


            default:
                assertionFailure()
            }
        }

        private static func setInitialSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_initial_size_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("initial size does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.initialSize = NSMakeSize(Double(v.width), Double(v.height))


            default:
                assertionFailure()
            }
        }

        private static func resetWindowSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("reset window size does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyResetWindowSize,
                    object: surfaceView
                )


            default:
                assertionFailure()
            }
        }

        private static func setCellSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_cell_size_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
                }

            default:
                assertionFailure()
            }
        }

        private static func renderInspector(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.inspectorNeedsDisplay,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func rendererHealth(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_renderer_health_e) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: [
                        "health": v,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func keySequence(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_key_sequence_s) {
            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("key sequence does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                if v.active {
                    NotificationCenter.default.post(
                        name: Notification.didContinueKeySequence,
                        object: surfaceView,
                        userInfo: [
                            Notification.KeySequenceKey: keyboardShortcut(for: v.trigger) as Any
                        ]
                    )
                } else {
                    NotificationCenter.default.post(
                        name: Notification.didEndKeySequence,
                        object: surfaceView
                    )
                }

            default:
                assertionFailure()
            }
        }

        private static func configReload(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_reload_config_s)
        {
            logger.info("config reload notification")

            guard let app_ud = ghostty_app_userdata(app) else { return }
            let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()

            switch (target.tag) {
            case GHOSTTY_TARGET_APP:
                ghostty.reloadConfig(soft: v.soft)
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                ghostty.reloadConfig(surface: surface, soft: v.soft)

            default:
                assertionFailure()
            }
        }

        private static func configChange(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_config_change_s) {
                logger.info("config change notification")

                // Clone the config so we own the memory. It'd be nicer to not have to do
                // this but since we async send the config out below we have to own the lifetime.
                // A future improvement might be to add reference counting to config or
                // something so apprt's do not have to do this.
                let config = Config(clone: v.config)

                switch (target.tag) {
                case GHOSTTY_TARGET_APP:
                    // Notify the world that the app config changed
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )

                    // We also REPLACE our app-level config when this happens. This lets
                    // all the various things that depend on this but are still theme specific
                    // such as split border color work.
                    guard let app_ud = ghostty_app_userdata(app) else { return }
                    let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
                    ghostty.config = config

                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )

                default:
                    assertionFailure()
                }
            }

        private static func colorChange(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            change: ghostty_action_color_change_s) {
                switch (target.tag) {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("color change does nothing with an app target")
                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .ghosttyColorDidChange,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyColorChangeKey: Action.ColorChange(c: change)
                        ]
                    )

                default:
                    assertionFailure()
                }
        }


        // MARK: User Notifications

        /// Handle a received user notification. This is called when a user notification is clicked or dismissed by the user
        func handleUserNotification(response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = delegate?.findSurface(forUUID: uuid) else { return }

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

        #endif
    }
}
