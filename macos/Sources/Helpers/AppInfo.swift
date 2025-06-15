import Foundation

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    if let _ = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
        return true
    }

    return false
}

/// True if we have liquid glass available.
func hasLiquidGlass() -> Bool {
    // Can't have liquid glass unless we're in macOS 26+
    if #unavailable(macOS 26.0) {
        return false
    }

    // If we aren't running SDK 26.0 or later then we definitely
    // do not have liquid glass.
    guard let sdkName = Bundle.main.infoDictionary?["DTSDKName"] as? String else {
        // If we don't have this, we assume we're built against the latest
        // since we're on macOS 26+
        return true
    }

    // If the SDK doesn't start with macosx then we just assume we
    // have it because we already verified we're on macOS above.
    guard sdkName.hasPrefix("macosx") else {
        return true
    }

    // The SDK version must be at least 26
    let versionString = String(sdkName.dropFirst("macosx".count))
    guard let major = if let dotIndex = versionString.firstIndex(of: ".") {
        Int(String(versionString[..<dotIndex]))
    } else {
        Int(versionString)
    } else { return true }

    // Note: we could also check for the UIDesignRequiresCompatibility key
    // but our project doesn't use it so there's no point.
    return major >= 26
}
