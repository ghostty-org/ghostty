import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHChildProcessTests {
    @Test func inheritsForegroundProcessGroup() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["EXPECTED_PGID"] = String(getpgrp())
        let status = try SSHChildProcess.run(executable: "/bin/sh", arguments: ["-c",
            "[ \"$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')\" = \"$EXPECTED_PGID\" ]"], environment: environment)
        #expect(status == 0)
    }

    @Test func preservesExitStatusAndArgumentBoundaries() throws {
        let status = try SSHChildProcess.run(executable: "/bin/sh", arguments: ["-c",
            "[ \"$1\" = 'a b' ] || exit 99; exit 7", "test", "a b"], environment: ProcessInfo.processInfo.environment)
        #expect(status == 7)
    }
}
