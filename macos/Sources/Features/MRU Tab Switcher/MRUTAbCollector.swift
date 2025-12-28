import AppKit
import SwiftUI

class MRUTabCollector {
  static func collectAllTabs() -> [MRUTabEntry] {
    var entries: [MRUTabEntry] = []

    for window in NSApp.windows {
      guard let controller = window.windowController as? BaseTerminalController else {
        continue
      }

      if let surface = controller.focusedSurface {
        let entry = MRUTabEntry(
          id: surface.id,
          title: controller.window?.title ?? surface.title,
          subtitle: surface.pwd,
          tabColor: (window as? TerminalWindow)?.tabColor.displayColor.map { Color(nsColor: $0) },
          focusInstant: surface.focusInstant,
          window: window
        )
        entries.append(entry)
      }
    }

    return entries
  }
}
