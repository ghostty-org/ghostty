import Foundation

/// A literal line of terminal input. This model never launches a process.
struct QuickCommand: Codable, Identifiable, Equatable {
    enum Action: String, Codable {
        case insert
        case execute
    }

    var id = UUID()
    var title: String
    var command: String
    var action: Action = .insert
    var group: String?

    var validationError: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a name for the command."
        }
        if command.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a command."
        }
        var fieldsToCheck = [title, command]
        if let group, !group.isEmpty {
            fieldsToCheck.append(group)
        }
        if fieldsToCheck.contains(where: { text in
            text.utf8.contains { $0 < 0x20 || $0 == 0x7f }
        }) {
            return "Use a single line without control characters."
        }
        return nil
    }

    static let automaticPlaceholders: Set<String> = ["clipboard", "selection"]

    /// Placeholders in `<var>` or `{var}` format in order of appearance
    var placeholders: [String] {
        var names: [String] = []
        guard let regex = try? NSRegularExpression(pattern: "(?:<([^>\\s]+)>|\\{([^}\\s]+)\\})") else { return [] }
        let nsString = command as NSString
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            let range1 = match.range(at: 1)
            let range2 = match.range(at: 2)
            let name: String
            if range1.location != NSNotFound {
                name = nsString.substring(with: range1)
            } else if range2.location != NSNotFound {
                name = nsString.substring(with: range2)
            } else {
                continue
            }
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Placeholders that require user input (excludes automatic variables like clipboard and selection)
    var manualPlaceholders: [String] {
        placeholders.filter { !Self.automaticPlaceholders.contains($0.lowercased()) }
    }

    func resolvedCommand(with values: [String: String]) -> String {
        var result = command
        for (placeholder, value) in values {
            result = result.replacingOccurrences(of: "<\(placeholder)>", with: value)
            result = result.replacingOccurrences(of: "{\(placeholder)}", with: value)
        }
        return result
    }

    /// Resolves both smart variables (clipboard, selection) and user-supplied values
    func autoResolvedCommand(clipboard: String? = nil, selection: String? = nil, values: [String: String] = [:]) -> String {
        var merged = values
        if let clipboard {
            merged["clipboard"] = clipboard
        }
        if let selection {
            merged["selection"] = selection
        }
        return resolvedCommand(with: merged)
    }

    /// `text:` decodes escapes once and writes directly to the PTY. Encoding
    /// every byte avoids interpreting shell quotes or literal backslashes.
    func bindingAction(customText: String? = nil, execute: Bool, force: Bool = false) -> String? {
        guard validationError == nil, force || customText != nil || !execute || action == .execute else { return nil }
        let textToSend = customText ?? command
        var bytes = Array(textToSend.utf8)
        if execute { bytes.append(0x0d) }
        return "text:" + bytes.map { String(format: "\\x%02x", $0) }.joined()
    }

    func duplicate() -> Self {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
