import Foundation

/// AppleScript record support for `Ghostty.SurfaceConfiguration`.
///
/// This keeps scripting conversion at the data-structure boundary so AppleScript
/// can pass records by value (`new surface configuration`, assign, copy, mutate)
/// without introducing an additional wrapper type.
extension Ghostty.SurfaceConfiguration: ScriptRecord {
    init(scriptRecord source: NSDictionary?) throws {
        self.init()

        guard let source else {
            return
        }

        guard let raw = source as? [String: Any] else {
            throw RecordParseError.invalidType(parameter: "configuration", expected: "a surface configuration record")
        }

        if let rawFontSize = raw["fontSize"] {
            guard let number = rawFontSize as? NSNumber else {
                throw RecordParseError.invalidType(parameter: "font size", expected: "a number")
            }

            let value = number.doubleValue
            guard value.isFinite else {
                throw RecordParseError.invalidValue(parameter: "font size", message: "must be a finite number")
            }

            if value < 0 {
                throw RecordParseError.invalidValue(parameter: "font size", message: "must be a positive number")
            }

            if value > 0 {
                fontSize = Float32(value)
            }
        }

        if let rawWorkingDirectory = raw["workingDirectory"] {
            guard let workingDirectory = rawWorkingDirectory as? String else {
                throw RecordParseError.invalidType(parameter: "initial working directory", expected: "text")
            }

            if !workingDirectory.isEmpty {
                self.workingDirectory = workingDirectory
            }
        }

        if let rawCommand = raw["command"] {
            guard let command = rawCommand as? String else {
                throw RecordParseError.invalidType(parameter: "command", expected: "text")
            }

            if !command.isEmpty {
                self.command = command
            }
        }

        if let rawInitialInput = raw["initialInput"] {
            guard let initialInput = rawInitialInput as? String else {
                throw RecordParseError.invalidType(parameter: "initial input", expected: "text")
            }

            if !initialInput.isEmpty {
                self.initialInput = initialInput
            }
        }

        if let rawWaitAfterCommand = raw["waitAfterCommand"] {
            if let boolValue = rawWaitAfterCommand as? Bool {
                waitAfterCommand = boolValue
            } else if let numericValue = rawWaitAfterCommand as? NSNumber {
                waitAfterCommand = numericValue.boolValue
            } else {
                throw RecordParseError.invalidType(parameter: "wait after command", expected: "boolean")
            }
        }

        if let assignments = raw["environmentVariables"] as? [String], !assignments.isEmpty {
            environmentVariables = try Self.parseScriptEnvironmentAssignments(assignments)
        }
    }

    var dictionaryRepresentation: NSDictionary {
        var record: [String: Any] = [
            "fontSize": 0,
            "workingDirectory": "",
            "command": "",
            "initialInput": "",
            "waitAfterCommand": false,
            "environmentVariables": [String](),
        ]

        if let fontSize {
            record["fontSize"] = NSNumber(value: fontSize)
        }

        if let workingDirectory {
            record["workingDirectory"] = workingDirectory
        }

        if let command {
            record["command"] = command
        }

        if let initialInput {
            record["initialInput"] = initialInput
        }

        if waitAfterCommand {
            record["waitAfterCommand"] = true
        }

        if !environmentVariables.isEmpty {
            record["environmentVariables"] = environmentVariables.map { "\($0.key)=\($0.value)" }
        }

        return record as NSDictionary
    }

    private static func parseScriptEnvironmentAssignments(_ assignments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]

        for assignment in assignments {
            guard let separator = assignment.firstIndex(of: "=") else {
                throw RecordParseError.invalidValue(
                    parameter: "environment variables",
                    message: "expected KEY=VALUE, got \"\(assignment)\""
                )
            }

            let key = String(assignment[..<separator])
            let valueStart = assignment.index(after: separator)
            let value = String(assignment[valueStart...])
            result[key] = value
        }

        return result
    }
}
