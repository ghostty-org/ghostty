import Carbon

class KeyboardLayout {
    enum PreeditStrategy: Equatable {
        case native
        case streamToTerminal
    }

    private static var currentInputSource: TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = currentInputSource,
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = unsafeBitCast(sourceIdPointer, to: CFString.self)
            return sourceId as String
        }

        return nil
    }

    static var preeditStrategy: PreeditStrategy {
        guard let source = currentInputSource else { return .native }

        let sourceId: String? = if let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) {
            unsafeBitCast(pointer, to: CFString.self) as String
        } else {
            nil
        }

        let languages: [String] = if let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceLanguages
        ) {
            unsafeBitCast(pointer, to: CFArray.self) as? [String] ?? []
        } else {
            []
        }

        return preeditStrategy(id: sourceId, languages: languages)
    }

    static func preeditStrategy(
        id: String?,
        languages: [String]
    ) -> PreeditStrategy {
        if id?.localizedCaseInsensitiveContains("vietnamese") == true {
            return .streamToTerminal
        }

        let isVietnamese = languages.contains { language in
            let language = language.lowercased()
            return language == "vi" ||
                language.hasPrefix("vi-") ||
                language.hasPrefix("vi_")
        }

        return isVietnamese ? .streamToTerminal : .native
    }
}
