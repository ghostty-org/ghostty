import Foundation
import GhosttyKit

enum TerminalAgentHooks {
    static func apply(to config: inout Ghostty.SurfaceConfiguration) {
        if ProcessInfo.processInfo.environment["GHOSTREE_DISABLE_AGENT_HOOKS"] == "1" {
            return
        }

        AgentHookInstaller.ensureInstalled()

        config.environmentVariables["GHOSTREE_AGENT_EVENTS_DIR"] = AgentStatusPaths.eventsCacheDir.path
        config.environmentVariables["GHOSTREE_AGENT_BIN_DIR"] = AgentStatusPaths.binDir.path

        let binDir = AgentStatusPaths.binDir.path
        let currentPath = config.environmentVariables["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        if currentPath.isEmpty {
            config.environmentVariables["PATH"] = binDir
            return
        }

        if currentPath.contains("\(binDir):") || currentPath.hasSuffix(":\(binDir)") || currentPath == binDir {
            return
        }

        config.environmentVariables["PATH"] = "\(binDir):\(currentPath)"
    }
}
