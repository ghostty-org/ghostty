import AppKit
import Combine
import SimPaneKit

/// Per-window state for the iOS simulator pane.
///
/// One of these belongs to each terminal window (see `BaseTerminalController`).
/// It owns the `SimulatorSession`, which in turn owns the view that renders the
/// device, so the pane can be hidden and shown without tearing the device down.
///
/// Nothing here touches a private framework: SimPaneKit reports whether the
/// machine can mirror at all, and every entry point is a no-op when it cannot.
@MainActor
class SimulatorPaneModel: ObservableObject {
    /// Persisted under a `simpane.` prefix in Ghostty's defaults (not
    /// `.standard`, so the debug suite override still isolates state).
    private enum Key {
        static let visible = "simpane.paneVisible"
        static let split = "simpane.paneSplit"
        static let device = "simpane.lastDeviceUDID"
    }

    /// Whether this machine can mirror a simulator, and why not when it cannot.
    /// Evaluated once: it shells out to `xcode-select` and cannot change while
    /// the app runs.
    static let support: SimPaneSupport = SimulatorSession.support()

    // MARK: Published state

    @Published var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            UserDefaults.ghostty.set(isVisible, forKey: Key.visible)
            if isVisible {
                Task { await refreshDevices() }
            } else {
                // Closing the pane releases the surface but never shuts the
                // device down: the user may still be using it elsewhere.
                detach()
            }
        }
    }

    /// Fraction of the window given to the terminal. The sidebar gets the rest.
    ///
    /// The plan asked for a persisted *width*; `SplitView` is fraction-based, and
    /// a fraction is also what survives a window resize sensibly, so that is what
    /// is stored.
    @Published var split: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(split), forKey: Key.split) }
    }

    @Published var selectedUDID: String? {
        didSet {
            guard selectedUDID != oldValue else { return }
            UserDefaults.ghostty.set(selectedUDID, forKey: Key.device)
            // Switching devices means the old session is meaningless.
            detach()
        }
    }

    @Published private(set) var devices: [SimDeviceInfo] = []
    @Published private(set) var state: SimulatorSession.State = .idle
    @Published private(set) var status: String?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var keyboardGoesToSimulator: Bool = false

    /// Non-nil once the pane has attached to a device.
    private(set) var session: SimulatorSession?

    /// Called when the pane hands the keyboard back, so the window can return
    /// focus to the terminal.
    var onFocusReleased: (() -> Void)?

    // MARK: Init

    init() {
        let defaults = UserDefaults.ghostty
        // Default closed. A terminal that sprouts a simulator on first launch
        // would be a surprise, and booting a device is not free.
        self.isVisible = defaults.bool(forKey: Key.visible) && Self.support.isSupported
        let storedSplit = defaults.object(forKey: Key.split) as? Double
        self.split = CGFloat(storedSplit ?? 0.68)
        self.selectedUDID = defaults.string(forKey: Key.device)

        if case .unsupported(let reason) = Self.support {
            status = reason
        }
    }

    var selectedDevice: SimDeviceInfo? {
        guard let selectedUDID else { return nil }
        return devices.first { $0.udid == selectedUDID }
    }

    var isAttached: Bool { session?.isAttached ?? false }

    // MARK: Devices

    /// Reloads the device list. Runs `simctl`, so it never happens on the main
    /// thread and never happens during view layout.
    func refreshDevices() async {
        guard Self.support.isSupported else { return }
        let listed = await Task.detached { SimulatorSession.listDevices() }.value
        devices = listed
        // Fall back to a sensible device if nothing is remembered or the
        // remembered one is gone.
        if selectedUDID == nil || !listed.contains(where: { $0.udid == selectedUDID }) {
            selectedUDID = SimulatorSession.preferredDevice()?.udid ?? listed.first?.udid
        }
    }

    // MARK: Lifecycle

    /// Boots the selected device if needed and starts mirroring it.
    func attach() async {
        guard Self.support.isSupported, !isBusy else { return }
        guard let udid = selectedUDID else {
            status = "No simulator device selected."
            return
        }
        if session?.isAttached == true { return }

        isBusy = true
        defer { isBusy = false }
        status = nil

        do {
            let session = try SimulatorSession(udid: udid)
            session.delegate = self
            session.onFocusReleased = { [weak self] in self?.onFocusReleased?() }
            session.onFocusChanged = { [weak self] focused in
                self?.keyboardGoesToSimulator = focused
            }
            self.session = session
            try await session.bootIfNeeded()
            await refreshDevices()
        } catch {
            status = error.localizedDescription
            session = nil
        }
    }

    /// Releases the mirror. The device keeps running.
    func detach() {
        session?.detach()
        session = nil
        keyboardGoesToSimulator = false
        state = .idle
    }

    func shutdownDevice() async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await session.shutdown()
            self.session = nil
            await refreshDevices()
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Actions

    func press(_ button: HardwareButton) {
        session?.pressButton(button)
    }

    /// Writes a `simctl` screenshot to the Desktop and reveals it, which is what
    /// a user reaching for a screenshot button almost always wants next.
    func saveScreenshot() async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await session.screenshotPNG()
            let name = (selectedDevice?.name ?? "Simulator")
                .replacingOccurrences(of: "/", with: "-")
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .appendingPathComponent("\(name) \(stamp).png")
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - SimulatorSessionDelegate

// The callbacks are documented to arrive on the main queue, but they originate
// inside SimPaneKit and are declared nonisolated, so they hop explicitly rather
// than assume.
extension SimulatorPaneModel: SimulatorSessionDelegate {
    nonisolated func simulatorSession(
        _ session: SimulatorSession, didChangeState state: SimulatorSession.State
    ) {
        Task { @MainActor in self.state = state }
    }

    nonisolated func simulatorSession(_ session: SimulatorSession, didFailWith error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = message }
    }
}
