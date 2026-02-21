import Foundation

enum RestorablePath {
    static func normalizedExistingDirectoryPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return standardized
    }

    static func existingDirectoryURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return standardized
    }
}
