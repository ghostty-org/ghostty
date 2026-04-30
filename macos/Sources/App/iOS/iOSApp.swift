import SwiftUI
import GhosttyKit

@main
struct Ghostty_iOSApp: App {
    @StateObject private var ghostty_app: Ghostty.App

    init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            preconditionFailure("Initialize ghostty backend failed")
        }
        _ghostty_app = StateObject(wrappedValue: Ghostty.App())
    }

    var body: some Scene {
        WindowGroup {
            iOS_GhosttyTerminal()
                .environmentObject(ghostty_app)
        }
    }
}

struct iOS_GhosttyTerminal: View {
    @EnvironmentObject private var ghostty_app: Ghostty.App

    var body: some View {
        ZStack {
            // Make sure that our background color extends to all parts of the screen
            Color(ghostty_app.config.backgroundColor).ignoresSafeArea()

            Ghostty.Terminal()
        }
    }
}

struct iOS_GhosttyInitView: View {
    @EnvironmentObject private var ghostty_app: Ghostty.App

    var body: some View {
        VStack {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            Text("Ghostty")
            Text("State: \(ghostty_app.readiness.rawValue)")
        }
        .padding()
    }
}
