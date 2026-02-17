import AppKit
import UniformTypeIdentifiers

extension NSWorkspace {
    /// Returns the URL of the default text editor application.
    /// - Returns: The URL of the default text editor, or nil if no default text editor is found.
    var defaultTextEditor: URL? {
        defaultApplicationURL(forContentType: UTType.plainText.identifier)
    }
    
    /// Returns the URL of the default application for opening files with the specified content type.
    /// - Parameter contentType: The content type identifier (UTI) to find the default application for.
    /// - Returns: The URL of the default application, or nil if no default application is found.
    func defaultApplicationURL(forContentType contentType: String) -> URL? {
        return LSCopyDefaultApplicationURLForContentType(
            contentType as CFString,
            .all,
            nil
        )?.takeRetainedValue() as? URL
    }
    
    /// Returns the URL of the default application for opening files with the specified file extension.
    /// - Parameter ext: The file extension to find the default application for.
    /// - Returns: The URL of the default application, or nil if no default application is found.
    func defaultApplicationURL(forExtension ext: String) -> URL? {
        guard let uti = UTType(filenameExtension: ext) else { return nil}
        return defaultApplicationURL(forContentType: uti.identifier)
    }
    
    /// Checks if Ghostty is the default terminal application.
    /// - Returns: True if Ghostty is the default application for handling public.unix-executable files.
    var isGhosttyDefaultTerminal: Bool {
        let ghosttyURL = Bundle.main.bundleURL
        guard let defaultAppURL = defaultApplicationURL(forContentType: "public.unix-executable") else {
            return false
        }
        // Compare bundle paths
        return ghosttyURL.path == defaultAppURL.path
    }
    
    /// Sets Ghostty as the default terminal application.
    /// - Throws: An error if the application bundle cannot be located or if setting the default fails.
    func setGhosttyAsDefaultTerminal() throws {
        let ghosttyURL = Bundle.main.bundleURL
        
        // Create UTType for unix executables
        guard let unixExecutableType = UTType("public.unix-executable") else {
            throw NSError(
                domain: "com.mitchellh.ghostty",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create UTType for public.unix-executable"]
            )
        }
        
        // Use NSWorkspace API to set the default application
        // This API is available on macOS 12.0+, Ghostty supports 13.0+, so it's compatible
        try setDefaultApplication(at: ghosttyURL, toOpen: unixExecutableType)
    }
}
