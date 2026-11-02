import Foundation
import Darwin

/// A remote viewer running inside a local managed PTY. Its lifetime is independent
/// of the App's window, while its descriptor supplies remote split/file context.
struct SessionRuntimeInlineSession: Codable, Equatable {
    let descriptor: SessionRuntimeDescriptor
    let pane: UUID
    let connectionID: String
    let socket: URL
    let helperPID: Int32
    let bootID: UUID
    var workingDirectory: String?
    var localPane: UUID?
    var localDescriptor: SessionRuntimeDescriptor?
    var passwordInput: Bool?

    var isRunningInThisBoot: Bool {
        helperPID > 1 &&
            bootID == Self.currentBootID &&
            kill(helperPID, 0) == 0
    }

    static let currentBootID: UUID? = {
        var bytes = [CChar](repeating: 0, count: 128)
        var count = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { return nil }
        return UUID(uuidString: String(cString: bytes))
    }()

    var replay: SSHReplayDescriptor? {
        guard let connection = descriptor.connection else { return nil }
        return .init(version: 1, ssh: connection.executablePath, forwardEnv: true,
                     terminfo: true, cache: true, args: connection.options + [connection.destination],
                     localWorkingDirectory: connection.localWorkingDirectory)
    }

    var restorationSignal: Ghostty.ContextSignal? {
        guard let connection = descriptor.connection else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.~"))
        let cwd = workingDirectory.flatMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        let alias = connection.destination.split(separator: "@").last.map(String.init) ?? connection.destination
        return .init(action: .start, id: connectionID,
                     metadata: "type=remote;targethost=\(alias)" + (cwd.map { ";cwd=\($0)" } ?? ""))
    }
}
