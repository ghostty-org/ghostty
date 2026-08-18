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

                Spacer()
                focusBadge
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var devicePicker: some View {
        Picker("", selection: Binding(
            get: { model.selectedUDID ?? "" },
            set: { model.selectedUDID = $0.isEmpty ? nil : $0 }
        )) {
            if model.devices.isEmpty {
                Text("No devices").tag("")
            }
            ForEach(model.devices) { device in
                Text("\(device.name) — \(device.runtime)").tag(device.udid)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .disabled(model.isAttached || model.isBusy)
    }

    @ViewBuilder
    private var startStopButton: some View {
        if model.isAttached {
            button("stop.fill", "Shut down this device") {
                Task { await model.shutdownDevice() }
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
