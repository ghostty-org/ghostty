import AppKit
import SwiftUI
import SimPaneKit

/// The simulator sidebar: a slim toolbar above a live mirror of the device.
struct SimulatorPaneView: View {
    @ObservedObject var model: SimulatorPaneModel

    var body: some View {
        VStack(spacing: 0) {
            SimulatorPaneToolbar(model: model)
            Divider()

            if let session = model.session {
                SimulatorMirror(session: session)
            } else {
                placeholder
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Populate the picker as soon as the pane appears; attaching is a
            // deliberate act, so it waits for the user.
            await model.refreshDevices()
        }
        // A device can be booted or shut down from Xcode, Simulator.app, or a
        // terminal. Refreshing when the app comes forward keeps the list honest
        // without polling for it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshDevices() }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "iphone")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                Text("Not attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toolbar

private struct SimulatorPaneToolbar: View {
    @ObservedObject var model: SimulatorPaneModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                devicePicker

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    startStopButton
                }
            }

            HStack(spacing: 4) {
                button("house", "Home") { model.press(.home) }
                button("lock", "Lock") { model.press(.lock) }
                button("camera", "Save a screenshot to the Desktop") {
                    Task { await model.saveScreenshot() }
                }
                .disabled(!model.isAttached)

                // Red while running, so a recording left going is obvious.
                button(model.isRecording ? "stop.circle.fill" : "record.circle",
                       model.isRecording
                           ? "Stop recording and reveal the movie"
                           : "Record the screen to a movie on the Desktop") {
                    Task { await model.toggleRecording() }
                }
                .disabled(!model.isAttached)
                .foregroundStyle(model.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))

                button("power", "Shut this device down") {
                    Task { await model.shutdownDevice() }
                }
                .disabled(!model.isAttached || model.isBusy)

                button("macwindow.on.rectangle", "Open this device in Simulator.app") {
                    Task { await model.openInSimulatorApp() }
                }
                .disabled(!model.isAttached || model.isBusy)

                Spacer()
                focusBadge
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var devicePicker: some View {
        Menu {
            if model.devices.isEmpty {
                Text("No devices")
            } else {
                // Booted devices get their own section at the top. With thirty
                // simulators installed, the one already running is nearly always
                // the one being reached for, and hunting for it inside a version
                // group defeats the point. They deliberately appear twice.
                if !model.runningDevices.isEmpty {
                    Section("Running") {
                        ForEach(model.runningDevices) { deviceItem($0) }
                    }
                }

                ForEach(model.devicesByRuntime) { group in
                    Section(group.runtime) {
                        ForEach(group.devices) { deviceItem($0) }
                    }
                }
            }

            Divider()
            Button("Refresh") {
                Task { await model.refreshDevices() }
            }
        } label: {
            Text(selectionLabel)
        }
        .controlSize(.small)
        .disabled(model.isAttached || model.isBusy)
        .help(model.isAttached
              ? "Shut the device down to pick a different one"
              : "Choose a simulator to mirror")
    }

    /// One device row. Running devices carry a filled dot so they can be picked
    /// out at a glance inside their version group too, not only in "Running".
    @ViewBuilder
    private func deviceItem(_ device: SimDeviceInfo) -> some View {
        Button {
            model.selectedUDID = device.udid
        } label: {
            if device.isBooted {
                Label(device.name, systemImage: "circle.fill")
            } else {
                Text(device.name)
            }
        }
    }

    private var selectionLabel: String {
        guard let device = model.selectedDevice else { return "No device" }
        let name = "\(device.name) — \(device.runtime)"
        return device.isBooted ? "● \(name)" : name
    }

    @ViewBuilder
    private var startStopButton: some View {
        if model.isAttached {
            // Detach, not shut down: the power button next to it does that, and
            // two controls that both kill the device would be a trap.
            button("eject.fill", "Stop mirroring (the device keeps running)") {
                model.detach()
            }
        } else {
            button("play.fill", "Boot and mirror this device") {
                Task { await model.attach() }
            }
            .disabled(model.selectedUDID == nil)
        }
    }

    /// Says out loud where typing goes. The mirror also draws an accent border
    /// around the device screen; in a terminal, one signal is not enough.
    @ViewBuilder
    private var focusBadge: some View {
        if model.keyboardGoesToSimulator {
            Text("keys → simulator")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.25), in: Capsule())
                .help("Press Escape twice to give the keyboard back to the terminal")
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void)
        -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - The mirror itself

/// Hosts the `NSView` that SimPaneKit renders the device into.
///
/// The view belongs to the session and is stable for its lifetime, so this only
/// ever installs it — it is never rebuilt underneath a running device.
private struct SimulatorMirror: NSViewRepresentable {
    let session: SimulatorSession

    func makeNSView(context: Context) -> NSView {
        session.mirrorView
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
