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
}
