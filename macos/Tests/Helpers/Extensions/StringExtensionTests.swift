import Testing
@testable import Ghostty

struct StringExtensionTests {
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
    func shellQuoted(input: String, expected: String) {
        #expect(input.shellQuoted() == expected)
    }
}
