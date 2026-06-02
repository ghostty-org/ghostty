@testable import Ghostty
import Testing

struct IPCServerTests {
    // MARK: - title

    @Test func titleFlag() {
        let config = IPCServer.surfaceConfiguration(from: ["--title=My Window"])
        #expect(config.title == "My Window")
    }

    @Test func titleFlagWithSpaces() {
        let config = IPCServer.surfaceConfiguration(from: ["--title=REMOTE: nutty-strawberry"])
        #expect(config.title == "REMOTE: nutty-strawberry")
    }

    @Test func titleFlagTrimsWhitespace() {
        let config = IPCServer.surfaceConfiguration(from: ["--title=  padded  "])
        #expect(config.title == "padded")
    }

    @Test func titleFlagEmpty() {
        let config = IPCServer.surfaceConfiguration(from: ["--title="])
        #expect(config.title == "")
    }

    @Test func noTitleFlag() {
        let config = IPCServer.surfaceConfiguration(from: [])
        #expect(config.title == nil)
    }

    // MARK: - working directory

    @Test func workingDirectoryFlag() {
        let config = IPCServer.surfaceConfiguration(from: ["--working-directory=/tmp/foo"])
        #expect(config.workingDirectory == "/tmp/foo")
    }

    @Test func workingDirectoryFlagTrimsWhitespace() {
        let config = IPCServer.surfaceConfiguration(from: ["--working-directory=  /tmp/foo  "])
        #expect(config.workingDirectory == "/tmp/foo")
    }

    @Test func noWorkingDirectoryFlag() {
        let config = IPCServer.surfaceConfiguration(from: [])
        #expect(config.workingDirectory == nil)
    }

    // MARK: - command

    @Test func commandFlag() {
        let config = IPCServer.surfaceConfiguration(from: ["--command=vim"])
        #expect(config.command == "vim")
    }

    @Test func noCommandFlag() {
        let config = IPCServer.surfaceConfiguration(from: [])
        #expect(config.command == nil)
    }

    // MARK: - -e (direct command)

    @Test func eFlagSingleArg() {
        let config = IPCServer.surfaceConfiguration(from: ["-e", "vim"])
        #expect(config.command == "vim")
    }

    @Test func eFlagMultipleArgs() {
        let config = IPCServer.surfaceConfiguration(from: ["-e", "ssh", "myhost"])
        #expect(config.command == "ssh myhost")
    }

    @Test func eFlagArgsWithSpacesAreQuoted() {
        let config = IPCServer.surfaceConfiguration(from: ["-e", "ssh", "my host"])
        // "my host" contains a space so Shell.quote wraps it in single quotes
        #expect(config.command == "ssh 'my host'")
    }

    @Test func eFlagConsumeAllRemainingArgs() {
        let config = IPCServer.surfaceConfiguration(from: ["-e", "dtach", "-A", "/tmp/work.sock", "bash", "-l"])
        #expect(config.command == "dtach -A /tmp/work.sock bash -l")
    }

    @Test func eFlagAfterOtherFlags() {
        let config = IPCServer.surfaceConfiguration(from: [
            "--title=My Window",
            "--working-directory=/tmp",
            "-e", "ssh", "myhost",
        ])
        #expect(config.title == "My Window")
        #expect(config.workingDirectory == "/tmp")
        #expect(config.command == "ssh myhost")
    }

    // MARK: - arg order / combinations

    @Test func allFlagsTogether() {
        let config = IPCServer.surfaceConfiguration(from: [
            "--working-directory=/home/user",
            "--title=REMOTE: work",
            "-e", "ssh", "myhost", "-t", "bash",
        ])
        #expect(config.workingDirectory == "/home/user")
        #expect(config.title == "REMOTE: work")
        #expect(config.command == "ssh myhost -t bash")
    }

    @Test func emptyArgs() {
        let config = IPCServer.surfaceConfiguration(from: [])
        #expect(config.title == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.command == nil)
    }

    @Test func unknownFlagsAreIgnored() {
        let config = IPCServer.surfaceConfiguration(from: ["--unknown-flag=value"])
        #expect(config.title == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.command == nil)
    }

    @Test func eFlagWithNoArgs() {
        // -e with nothing after it should produce no command
        let config = IPCServer.surfaceConfiguration(from: ["-e"])
        #expect(config.command == nil)
    }

    // MARK: - rssh real-world cases

    @Test func rsshNuttyCase() {
        let config = IPCServer.surfaceConfiguration(from: [
            "--working-directory=/Users/andtung/mp",
            "--title=REMOTE: nutty-strawberry",
            "-e", "rdev", "ssh", "traffic-envoy/nutty-strawberry", "--non-tmux",
        ])
        #expect(config.title == "REMOTE: nutty-strawberry")
        #expect(config.command == "rdev ssh traffic-envoy/nutty-strawberry --non-tmux")
    }

    @Test func rsshWorkCase() {
        let config = IPCServer.surfaceConfiguration(from: [
            "--working-directory=/Users/andtung/mp",
            "--title=REMOTE: ld1 work",
            "-e", "ssh", "andtung-ld1.linkedin.biz", "-t", "dtach -A /tmp/work.sock bash -l",
        ])
        #expect(config.title == "REMOTE: ld1 work")
        #expect(config.command != nil)
        #expect(config.command!.hasPrefix("ssh andtung-ld1.linkedin.biz"))
    }
}
