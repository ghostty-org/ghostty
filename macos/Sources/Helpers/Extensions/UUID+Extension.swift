import Foundation

extension UUID {
    /// Initialize a UUID from a CFUUID.
    init?(_ cfuuid: CFUUID) {
        guard let uuidString = CFUUIDCreateString(nil, cfuuid) as String? else { return nil }
        self.init(uuidString: uuidString)
    }
}
