import AppKit
import SwiftUI
import SimPaneKit

/// The simulator sidebar: a device picker above a live mirror, with the device
/// controls in a floating pill along the bottom.
struct SimulatorPaneView: View {
    @ObservedObject var model: SimulatorPaneModel

    var body: some View {
        VStack(spacing: 0) {
            SimulatorPaneHeader(model: model)
            Divider()

            if let session = model.session {
                SimulatorMirror(session: session)
            } else {
                placeholder
            }

            SimulatorPaneControls(model: model)
                .padding(.vertical, 10)
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

// MARK: - Header: which device, and whether it is mirrored

private struct SimulatorPaneHeader: View {
    @ObservedObject var model: SimulatorPaneModel

    var body: some View {
        HStack(spacing: 8) {
            devicePicker

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            } else {
                attachButton
            }
        }
        // Centred to sit over the device, matching the control capsule below.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // The badge is an overlay rather than part of the stack: in the stack it
        // would shift the picker off centre whenever focus moved to the device.
        .overlay(alignment: .trailing) {
            focusBadge.padding(.trailing, 8)
        }
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .controlSize(.regular)
        .fixedSize()
        .disabled(model.isAttached || model.isBusy)
        .help(model.isAttached
              ? "Stop mirroring to pick a different device"
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
    private var attachButton: some View {
        if model.isAttached {
            // Eject, not stop: the power button in the pill shuts the device
            // down, and two controls that both kill it would be a trap.
            Button {
                model.detach()
            } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Stop mirroring (the device keeps running)")
        } else {
            Button {
                Task { await model.attach() }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedUDID == nil)
            .help("Boot and mirror this device")
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
}

// MARK: - The control pill

/// Device controls, grouped into one capsule at the bottom of the pane.
///
/// Deliberately a single unit rather than loose buttons: these all act on the
/// device rather than on the pane, and keeping them together — away from the
/// picker — makes that distinction visible.
private struct SimulatorPaneControls: View {
    @ObservedObject var model: SimulatorPaneModel

    var body: some View {
        HStack(spacing: 0) {
            control("house", "Home") { model.press(.home) }
            separator
            control("lock", "Lock") { model.press(.lock) }
            separator
            control("camera", "Save a screenshot to the Desktop") {
                Task { await model.saveScreenshot() }
            }
            separator
            control(model.isRecording ? "stop.fill" : "video",
                    model.isRecording
                        ? "Stop recording and reveal the movie"
                        : "Record the screen to a movie on the Desktop",
                    tint: model.isRecording ? .red : nil) {
                Task { await model.toggleRecording() }
            }
            separator
            control("power", "Shut this device down", enabled: !model.isBusy) {
                Task { await model.shutdownDevice() }
            }
            separator
            control("rectangle.portrait.and.arrow.right",
                    "Open this device in Simulator.app",
                    enabled: !model.isBusy) {
                Task { await model.openInSimulatorApp() }
            }
        }
        .padding(.horizontal, 3)
        .background(
            Capsule().fill(Color.black.opacity(0.25))
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        // Everything here acts on a device, so none of it means anything without
        // one attached.
        .opacity(model.isAttached ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: model.isAttached)
    }

    private func control(
        _ symbol: String,
        _ help: String,
        tint: Color? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 30, height: 24)
                // The whole cell is the target, not just the glyph.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
        .disabled(!model.isAttached || !enabled)
        .help(help)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 14)
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
