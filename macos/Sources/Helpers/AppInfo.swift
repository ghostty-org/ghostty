import Foundation

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    if let _ = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
        return true
    }

    return false
}
