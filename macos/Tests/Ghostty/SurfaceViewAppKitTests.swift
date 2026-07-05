@testable import Ghostty
import AppKit
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }
}

@MainActor
struct QuickTerminalWindowTests {
    @Test func canShowOnFullscreenSpaces() {
        let window = QuickTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        window.awakeFromNib()

        #expect(window.styleMask.contains(.nonactivatingPanel))
    }

    @Test func activatesOnlyOutsideFullscreenSpaces() {
        #expect(QuickTerminalController.shouldActivateApplication(activeSpaceType: .user))
        #expect(!QuickTerminalController.shouldActivateApplication(activeSpaceType: .fullscreen))
    }

    @Test func mainScreenUsesFullscreenScreenWhenAvailable() {
        #expect(
            QuickTerminalScreen.resolveMainScreen(
                activeSpaceType: .fullscreen,
                activeSpaceScreen: "external",
                fullscreenSpaceScreen: nil,
                mainScreen: "built-in"
            ) == "external"
        )
        #expect(
            QuickTerminalScreen.resolveMainScreen(
                activeSpaceType: .user,
                activeSpaceScreen: "external",
                fullscreenSpaceScreen: nil,
                mainScreen: "built-in"
            ) == "built-in"
        )
        #expect(
            QuickTerminalScreen.resolveMainScreen(
                activeSpaceType: .fullscreen,
                activeSpaceScreen: nil,
                fullscreenSpaceScreen: nil,
                mainScreen: "built-in"
            ) == "built-in"
        )
        #expect(
            QuickTerminalScreen.resolveMainScreen(
                activeSpaceType: .user,
                activeSpaceScreen: "built-in",
                fullscreenSpaceScreen: "external",
                mainScreen: "built-in"
            ) == "external"
        )
    }

    @Test func mapsManagedDisplaySpacesToActiveSpaceDisplay() {
        let builtIn = UUID(uuidString: "37D8832A-2D66-02CA-B9F7-8F30A301B230")!
        let external = UUID(uuidString: "B733196D-2302-4B68-ACBC-BDA73E9E24BE")!
        let managedDisplaySpaces: [[String: Any]] = [
            [
                "Display Identifier": builtIn.uuidString,
                "Current Space": [
                    "ManagedSpaceID": 1,
                    "type": 0,
                ],
            ],
            [
                "Display Identifier": external.uuidString,
                "Current Space": [
                    "ManagedSpaceID": 118,
                    "type": 4,
                ],
            ],
        ]

        #expect(
            CGSSpace.displayUUID(
                for: CGSSpace(rawValue: 118),
                managedDisplaySpaces: managedDisplaySpaces
            ) == external
        )
    }

    @Test func resolvesCurrentFullscreenDisplay() {
        let builtIn = UUID(uuidString: "37D8832A-2D66-02CA-B9F7-8F30A301B230")!
        let external = UUID(uuidString: "B733196D-2302-4B68-ACBC-BDA73E9E24BE")!
        let managedDisplaySpaces: [[String: Any]] = [
            [
                "Display Identifier": builtIn.uuidString,
                "Current Space": [
                    "ManagedSpaceID": 1,
                    "type": 0,
                ],
            ],
            [
                "Display Identifier": external.uuidString,
                "Current Space": [
                    "ManagedSpaceID": 118,
                    "type": 4,
                    "pid": 1017,
                ],
            ],
        ]

        #expect(
            CGSSpace.currentFullscreenDisplayUUID(
                frontmostApplicationProcessIdentifier: 1017,
                managedDisplaySpaces: managedDisplaySpaces
            ) == external
        )
        #expect(
            CGSSpace.currentFullscreenDisplayUUID(
                frontmostApplicationProcessIdentifier: nil,
                managedDisplaySpaces: managedDisplaySpaces
            ) == external
        )

        let multipleFullscreenDisplaySpaces: [[String: Any]] = [
            [
                "Display Identifier": builtIn.uuidString,
                "Current Space": [
                    "ManagedSpaceID": 2,
                    "type": 4,
                    "pid": 2000,
                ],
            ],
            [
                "Display Identifier": external.uuidString,
                "Current Space": [
                    "ManagedSpaceID": 118,
                    "type": 4,
                    "pid": 1017,
                ],
            ],
        ]

        #expect(
            CGSSpace.currentFullscreenDisplayUUID(
                frontmostApplicationProcessIdentifier: nil,
                managedDisplaySpaces: multipleFullscreenDisplaySpaces
            ) == nil
        )
        #expect(
            CGSSpace.currentFullscreenDisplayUUID(
                frontmostApplicationProcessIdentifier: 1017,
                managedDisplaySpaces: multipleFullscreenDisplaySpaces
            ) == external
        )
    }
}
