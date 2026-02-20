import Testing
@testable import Ghostty

struct ShellTests {
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
