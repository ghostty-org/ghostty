import Foundation
@testable import Ghostty
@testable import GhosttyKit

/// Create a temporary config file and delete it when this is deallocated
class TemporaryConfig: Ghostty.Config {
    enum Error: Swift.Error {
        case failedToLoad
    }

    let temporaryFile: URL

    init(_ configText: String, finalize: Bool = true) throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        // Suppress `error.FileIsEmpty`
        let text = configText.isEmpty ? " " : configText
        try text.write(to: temporaryFile, atomically: true, encoding: .utf8)
        self.temporaryFile = temporaryFile
        super.init(config: Self.loadConfig(at: temporaryFile.path(), finalize: finalize))
    }

    func reload(_ newConfigText: String?, finalize: Bool = true) throws {
        if let newConfigText {
            // Suppress `error.FileIsEmpty`
            let text = newConfigText.isEmpty ? " " : newConfigText
            try text.write(to: temporaryFile, atomically: true, encoding: .utf8)
        }
        guard let cfg = Self.loadConfig(at: temporaryFile.path(), finalize: finalize) else {
            throw Error.failedToLoad
        }
        clone(config: cfg)
    }

    var optionalAutoUpdateChannel: Ghostty.AutoUpdateChannel? {
        guard let config = self.config else { return nil }
        var v: UnsafePointer<Int8>?
        let key = "auto-update-channel"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        guard let ptr = v else { return nil }
        let str = String(cString: ptr)
        return Ghostty.AutoUpdateChannel(rawValue: str)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryFile)
    }
}
