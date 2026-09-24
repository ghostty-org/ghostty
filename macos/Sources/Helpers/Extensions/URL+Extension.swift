import Foundation
import System

extension URL {
    /// The decoded path with trailing separators removed, except for the root path.
    var pathWithoutTrailingSlash: String {
        FilePath(path(percentEncoded: false)).string
    }
}
