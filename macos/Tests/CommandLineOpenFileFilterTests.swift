import Testing
@testable import Ghostty

@Suite
struct CommandLineOpenFileFilterTests {
    @Test func requiresExecuteFlag() {
        let filter = CommandLineOpenFileFilter(
            arguments: ["ghostty", "/tmp/file.txt"],
            workingDirectory: "/tmp",
            fileExists: { _ in true }
        )

        #expect(!filter.shouldIgnore("/tmp/file.txt"))
    }

    @Test func ignoresExistingPathsAfterExecuteFlag() {
        let existing: Set<String> = [
            "/usr/bin/vim",
            "/tmp/project/file.txt",
            "/tmp/other.txt",
        ]
        let filter = CommandLineOpenFileFilter(
            arguments: [
                "ghostty",
                "/tmp/before.txt",
                "-e",
                "/usr/bin/vim",
                "./file.txt",
                "../other.txt",
                "missing.txt",
            ],
            workingDirectory: "/tmp/project",
            fileExists: { existing.contains($0) }
        )

        #expect(!filter.shouldIgnore("/tmp/before.txt"))
        #expect(filter.shouldIgnore("/usr/bin/vim"))
        #expect(filter.shouldIgnore("/tmp/project/file.txt"))
        #expect(filter.shouldIgnore("/tmp/other.txt"))
        #expect(!filter.shouldIgnore("/tmp/project/missing.txt"))
    }

    @Test func ignoresEachPathOnce() {
        let filter = CommandLineOpenFileFilter(
            arguments: ["ghostty", "-e", "./file.txt"],
            workingDirectory: "/tmp/project",
            fileExists: { $0 == "/tmp/project/file.txt" }
        )

        #expect(filter.shouldIgnore("./file.txt"))
        #expect(!filter.shouldIgnore("/tmp/project/file.txt"))
    }

    @Test func preservesUnrelatedOpenFileRequests() {
        let filter = CommandLineOpenFileFilter(
            arguments: ["ghostty", "-e", "vim", "/tmp/command-file.txt"],
            workingDirectory: "/tmp",
            fileExists: { $0 == "/tmp/command-file.txt" }
        )

        #expect(!filter.shouldIgnore("/tmp/finder-file.txt"))
        #expect(filter.shouldIgnore("/tmp/command-file.txt"))
    }

    @Test func normalizesFileURLs() {
        let existing: Set<String> = [
            "/tmp/project/file #100%.txt",
            "/tmp/project/directory",
        ]
        let filter = CommandLineOpenFileFilter(
            arguments: [
                "ghostty",
                "-e",
                "command",
                "./file #100%.txt",
                "./directory/",
            ],
            workingDirectory: "/tmp/project",
            fileExists: { existing.contains($0) }
        )

        #expect(filter.shouldIgnore("/tmp/project/file #100%.txt"))
        #expect(filter.shouldIgnore("/tmp/project/directory"))
    }
}
