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

        /// Returns a copy of the string quoted so that a shell treats it as a
        /// single, literal argument.
        ///
        /// This works like Python's `shlex.quote`. A string made only of
        /// letters, digits, and the characters `_@%+=:,./-` needs no quoting,
        /// so it's returned unchanged. Any other string is wrapped in single
        /// quotes, which stops the shell from interpreting spaces and special
        /// characters such as `$`, `*`, and `;`. Single quotes inside the
        /// string are preserved as well.
        ///
        /// ```swift
        /// Ghostty.Shell.quote("notes.txt")    // notes.txt
        /// Ghostty.Shell.quote("my file.txt")  // 'my file.txt'
        /// Ghostty.Shell.quote("$HOME")        // '$HOME'
        /// Ghostty.Shell.quote("it's")         // 'it'"'"'s'
        /// Ghostty.Shell.quote("")             // ''
        /// ```
        ///
        /// Use this when building a command for a shell to run. To insert a
        /// path at the cursor of a terminal instead, use ``escape(_:)``.
        ///
        /// - Important: Quoting only protects against how the shell reads a
        ///   command. If you send the result to a terminal as typed input,
        ///   first check the original string with
        ///   ``containsControlCharacters(_:)``. Control characters such as
        ///   Ctrl-U and Return take effect as they're typed, before the shell
        ///   ever sees the quotes.
        ///
        /// - Parameter str: The string to quote.
        /// - Returns: A version of `str` that a shell reads as one argument.
        static func quote(_ str: String) -> String {
            guard str.isEmpty || str.contains(Self.quoteUnsafe) else { return str }
            return "'" + str.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        }

        /// Returns a Boolean value indicating whether the string contains any
        /// control characters.
        ///
        /// Control characters are invisible codes that stand for actions
        /// rather than text, such as Return, Tab, Escape, and Ctrl-U. This
        /// checks for every Unicode control character: U+0000 through U+001F,
        /// U+007F (Delete), and U+0080 through U+009F.
        ///
        /// Call this before you send a string to a terminal as typed input,
        /// such as the `initialInput` of a new terminal. The terminal and
        /// the shell act on control characters the moment they arrive, so
        /// quoting the string doesn't help. A control character can even
        /// erase the opening quote. In this example, a file name hides
        /// Ctrl-U, the text `ls`, and Return:
        ///
        /// ```swift
        /// let path = "/tmp/Foo\u{15}ls\r"
        /// let input = "\(Ghostty.Shell.quote(path)); exit\n"
        ///
        /// // The shell receives:  '/tmp/Foo<Ctrl-U>ls<Return>'; exit
        /// // Ctrl-U erases the opening quote and path, then Return runs `ls`.
        /// ```
        ///
        /// Because control characters are also invisible on screen, you can't
        /// safely ask the user to confirm a string that contains them. Reject
        /// the string instead:
        ///
        /// ```swift
        /// guard !Ghostty.Shell.containsControlCharacters(path) else {
        ///     return false
        /// }
        ///
        /// config.initialInput = "\(Ghostty.Shell.quote(path)); exit\n"
        /// ```
        ///
        /// - Parameter str: The string to check.
        /// - Returns: `true` if `str` contains at least one control character,
        ///   otherwise `false`.
        static func containsControlCharacters(_ str: String) -> Bool {
            str.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }
}
