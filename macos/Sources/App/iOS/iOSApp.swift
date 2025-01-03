import SwiftUI

@main
struct Ghostty_iOSApp: App {
    @State private var ghostty_app = Ghostty.App()

    var body: some Scene {
        WindowGroup {
            iOS_GhosttyTerminal()
                .environment(ghostty_app)
        }
    }
}

struct iOS_GhosttyTerminal: View {
    @Environment(Ghostty.App.self) private var ghostty_app: Ghostty.App

    var body: some View {
        ZStack {
            // Make sure that our background color extends to all parts of the screen
            Color(ghostty_app.config.backgroundColor).ignoresSafeArea()

            Ghostty.Terminal()
        }
    }
}

struct iOS_GhosttyInitView: View {
    @Environment(Ghostty.App.self) private var ghostty_app: Ghostty.App

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
