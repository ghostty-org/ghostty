import SwiftUI

// We use an NSAlert instead of a SwiftUI confirmationDialog because the
// alert can accept return-key to confirm.
class QuitConfirmationDialogPresenter: ObservableObject {
    func showDialog() {
        let alert = NSAlert()
        alert.messageText = "Quit Ghostty?"

        alert.informativeText = "All terminal sessions will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        } else {
            NSApplication.shared.reply(toApplicationShouldTerminate: false)
        }
    }
}
