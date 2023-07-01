import SwiftUI
import GhosttyKit

struct ContentView: View {
    let ghostty: Ghostty.AppState
    
    // We need access to our app delegate to know if we're quitting or not.
    @EnvironmentObject private var appDelegate: AppDelegate
    
    // We need access to our window to know if we're the key window to determine
    // if we show the quit confirmation or not.
    @State private var window: NSWindow?
    
    // This is the dialog to ask user whether they want to quit.
    // We're using an NSAlert instead of a SwiftUI confirmationDialog because
    // SwiftUI's dialog don't support accepting the default action on return.
    @ObservedObject var dialogPresenter = QuitConfirmationDialogPresenter()

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
                .onChange(of: appDelegate.confirmQuit) { value in
                    guard value else { return }
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
        case .error:
            ErrorView()
                .onChange(of: appDelegate.confirmQuit) { value in
                    guard value else { return }
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
        case .ready:
            let confirmQuitting = Binding<Bool>(get: {
                self.appDelegate.confirmQuit && (self.window?.isKeyWindow ?? false)
            }, set: {
                self.appDelegate.confirmQuit = $0
            })
                                                        
            Ghostty.TerminalSplit(onClose: Self.closeWindow)
                .ghosttyApp(ghostty.app!)
                .background(WindowAccessor(window: $window))
                .onChange(of: confirmQuitting.wrappedValue) { value in
                    guard value else { return }
                    dialogPresenter.showDialog()
                    self.appDelegate.confirmQuit = false
                }
        }
    }
    
    static func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
}
