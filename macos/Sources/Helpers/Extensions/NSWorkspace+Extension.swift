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
}
