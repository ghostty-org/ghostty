extension String {
    /// True when the first scalar is an ASCII control character (C0 or DEL).
    var startsWithASCIIControlCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    func truncate(length: Int, trailing: String = "…") -> String {
        let maxLength = length - trailing.count
        guard maxLength > 0, !self.isEmpty, self.count > length else {
            return self
        }
        return self.prefix(maxLength) + trailing
    }

    func temporaryFile(_ filename: String = "temp") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension("txt")
        let string = self
        try? string.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Returns the path with the home directory abbreviated as ~.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if hasPrefix(home) {
            return "~" + dropFirst(home.count)
        }
        return self
    }

    /// Converts a four-character ASCII string to its `FourCharCode` (`UInt32`) value.
    var fourCharCode: UInt32 {
        assert(count <= 4, "FourCharCode string must be at most 4 characters")
        var result: UInt32 = 0
        for byte in utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }
}
