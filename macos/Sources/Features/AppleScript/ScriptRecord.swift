import Cocoa

/// Protocol to more easily implement AppleScript records in Swift.
protocol ScriptRecord {
    /// Initialize a default record.
    init()

    /// Initialize a record from the raw value from AppleScript.
    init(scriptRecord: NSDictionary?) throws

    /// Encode into the dictionary form for AppleScript.
    var dictionaryRepresentation: NSDictionary { get }
}

/// An error that can be thrown by `ScriptRecord.init(scriptRecord:)`. Any localized error
/// can be thrown but this is a common one.
enum RecordParseError: LocalizedError {
    case invalidType(parameter: String, expected: String)
    case invalidValue(parameter: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidType(let parameter, let expected):
            return "\(parameter) must be \(expected)."
        case .invalidValue(let parameter, let message):
            return "\(parameter) \(message)."
        }
    }
}
