import Foundation
import GhosttyKit
import SwiftUI

extension Ghostty {
    struct ChildExitedMessage {
        enum Level {
            case success, error
        }
        let text: String
        let level: Level

        init(_ message: ghostty_surface_message_childexited_s, threshold abnormalCommandExitRuntime: Duration) {
            var level: Level
            switch Int(message.exit_code) {
            case Int(EXIT_SUCCESS):
                level = .success
            default:
                level = .error
            }
            // See: Surface.zig/childExited
            // If our runtime was below some threshold then we assume that this
            // was an abnormal exit and we show an error message.
            if abnormalCommandExitRuntime >= .milliseconds(message.timetime_ms) {
                level = .error
                let measure = Measurement.init(value: Double(message.timetime_ms), unit: UnitDuration.milliseconds)
                let formatter = MeasurementFormatter()
                if message.timetime_ms > 1000 {
                    formatter.unitOptions = .naturalScale
                } else {
                    formatter.unitOptions = .providedUnit
                }
                formatter.locale = .init(identifier: "en_US")
                text = "Process exited after **`\(formatter.string(from: measure))`**. Press any key to close the terminal."
            } else {
                text = "Process exited. Press any key to close the terminal."
            }
            self.level = level
        }
    }
}
