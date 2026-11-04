import AppKit

extension NSAppleEventDescriptor {
    /// The bundle identifier of the process that sent this Apple event, if known.
    ///
    /// This prefers the sender's application-identifier entitlement, which the Apple
    /// Event system records on every event it delivers. That doesn't require any
    /// lookup, which matters because the sender may be a short-lived XPC service
    /// that isn't visible through `NSRunningApplication` yet when the event arrives.
    /// Falls back to the running application for the sender's pid.
    var senderBundleIdentifier: String? {
        if let id = attributeDescriptor(
            forKeyword: AEKeyword(keySenderApplicationIdentifierEntitlementAttr)
        )?.stringValue, !id.isEmpty {
            return id
        }

        if let pid = attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
           let app = NSRunningApplication(processIdentifier: pid) {
            return app.bundleIdentifier
        }

        return nil
    }

    /// Whether the sender expects us to be brought to the front alongside this
    /// event.
    ///
    /// It seems that LaunchServices sets this on open and reopen events when the
    /// caller asked for activation and it is absent when an app is opened in the
    /// background.
    var expectsActivation: Bool {
        paramDescriptor(
            forKeyword: AEKeyword(kAEApplicationActivationExpected)
        )?.booleanValue ?? false
    }
}
