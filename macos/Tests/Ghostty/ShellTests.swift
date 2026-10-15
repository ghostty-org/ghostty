import Testing
@testable import Ghostty

struct ShellTests {
    @Test(arguments: [
        ("hello", "hello"),
        ("", ""),
        ("file name", "file\\ name"),
        ("a\\b", "a\\\\b"),
        ("(foo)", "\\(foo\\)"),
        ("[bar]", "\\[bar\\]"),
        ("{baz}", "\\{baz\\}"),
        ("<qux>", "\\<qux\\>"),
        ("say\"hi\"", "say\\\"hi\\\""),
        ("it's", "it\\'s"),
        ("`cmd`", "\\`cmd\\`"),
        ("wow!", "wow\\!"),
        ("#comment", "\\#comment"),
        ("$HOME", "\\$HOME"),
        ("a&b", "a\\&b"),
        ("a;b", "a\\;b"),
        ("a|b", "a\\|b"),
        ("*.txt", "\\*.txt"),
        ("file?.log", "file\\?.log"),
        ("col1\tcol2", "col1\\\tcol2"),
        ("$(echo 'hi')", "\\$\\(echo\\ \\'hi\\'\\)"),
        ("/tmp/my file (1).txt", "/tmp/my\\ file\\ \\(1\\).txt"),
    ])
    func escape(input: String, expected: String) {
        #expect(Ghostty.Shell.escape(input) == expected)
    }

    @Test(arguments: [
        ("", "''"),
        ("filename", "filename"),
        ("abcABC123@%_-+=:,./", "abcABC123@%_-+=:,./"),
        ("file name", "'file name'"),
        ("file$name", "'file$name'"),
        ("file!name", "'file!name'"),
        ("file\\name", "'file\\name'"),
        ("it's", "'it'\"'\"'s'"),
        ("file$'name'", "'file$'\"'\"'name'\"'\"''"),
    ])
    func quote(input: String, expected: String) {
        #expect(Ghostty.Shell.quote(input) == expected)
    }

    @Test(arguments: [
        // Ordinary paths, including non-English text, are allowed.
        ("", false),
        ("/tmp/script.sh", false),
        ("/tmp/my file (1).command", false),
        ("/tmp/café/日本語.sh", false),

        // This emoji is joined with invisible zero-width joiners (U+200D).
        // Those are formatting characters, not control characters, so
        // they're allowed.
        ("/tmp/👨‍👩‍👧.sh", false),

        // Ctrl-U erases the line, then Return runs `ls`.
        ("/tmp/Foo\u{15}ls\r", true),

        // Common control characters.
        ("/tmp/a\nb", true),
        ("/tmp/a\rb", true),
        ("/tmp/a\tb", true),
        ("/tmp/a\u{00}b", true),
        ("/tmp/a\u{1B}b", true),

        // Delete, and a control character from the U+0080 to U+009F range.
        ("/tmp/a\u{7F}b", true),
        ("/tmp/a\u{9B}b", true),
    ])
    func containsControlCharacters(input: String, expected: Bool) {
        #expect(Ghostty.Shell.containsControlCharacters(input) == expected)
    }
}
