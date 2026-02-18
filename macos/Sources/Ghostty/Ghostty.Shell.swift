extension Ghostty {
    enum Shell {
        // Characters to escape in the shell.
        private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Escape shell-sensitive characters in a string by prefixing each with a
        /// backslash. Suitable for inserting paths/URLs into a live terminal buffer.
        static func escape(_ str: String) -> String {
            var result = str
            for char in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(char),
                    with: "\\\(char)"
                )
            }

            return result
        }

        private static let quoteUnsafe = /[^\w@%+=:,.\/-]/

        /// Returns a shell-quoted version of the string, like Python's shlex.quote.
        /// Suitable for building shell command lines that will be executed.
        static func quote(_ str: String) -> String {
            guard str.isEmpty || str.contains(Self.quoteUnsafe) else { return str }
            return "'" + str.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        }
    }
}
