import Foundation

enum RestorablePath {
    private static func hasRelativePathComponent(_ url: URL) -> Bool {
        let components = url.pathComponents
        return components.contains(".") || components.contains("..")
    }

    static func normalizedExistingDirectoryPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard !hasRelativePathComponent(url) else { return nil }
        let standardized = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return standardized
    }

    static func existingDirectoryURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard !hasRelativePathComponent(url) else { return nil }
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return standardized
    }
}
