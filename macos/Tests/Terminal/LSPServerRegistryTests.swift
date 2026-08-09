import Foundation
@testable import Ghostty
import Testing

/// The registry is a table, so these are table invariants.
///
/// The one that matters operationally is the install hint: none of these
/// servers is installed by default, so an entry without a usable hint turns
/// into a UI that says a language is unsupported on a machine where one
/// `npm i -g` would have fixed it.
struct LSPServerRegistryTests {
    @Test func everyEntryHasACommand() {
        for definition in LSPServerRegistry.all {
            #expect(!definition.languageID.isEmpty)
            #expect(!definition.displayName.isEmpty)
            #expect(!definition.command.isEmpty, "\(definition.languageID) has no command")
            #expect(!definition.command.contains(" "), "\(definition.languageID) packs args into the command")
        }
    }

    @Test func everyEntryHasAnInstallHint() {
        for definition in LSPServerRegistry.all {
            #expect(!definition.installHint.isEmpty, "\(definition.languageID) has no install hint")
        }
    }

    /// Arguments are passed to `Process` one at a time, so a single string
    /// holding `"--stdio --log"` would be handed over as one argument and
    /// rejected by the server.
    @Test func argumentsAreIndividualTokens() {
        for definition in LSPServerRegistry.all {
            for argument in definition.arguments {
                #expect(!argument.isEmpty, "\(definition.languageID) has an empty argument")
                #expect(!argument.contains(" "), "\(definition.languageID) has an unsplit argument")
            }
        }
    }

    @Test func languageIDsAreUnique() {
        let ids = LSPServerRegistry.all.map(\.languageID)

        #expect(Set(ids).count == ids.count)
    }

    @Test func anUnknownLanguageHasNoServer() {
        #expect(LSPServerRegistry.server(forLanguage: "brainfuck") == nil)
        #expect(LSPServerRegistry.server(forLanguage: "") == nil)
    }

    @Test func theExpectedLanguagesAreCovered() throws {
        let expected = [
            "typescript", "javascript", "vue", "swift", "kotlin",
            "python", "rust", "go", "json", "yaml"
        ]

        for languageID in expected {
            let definition = try #require(
                LSPServerRegistry.server(forLanguage: languageID),
                "no server for \(languageID)"
            )
            #expect(definition.languageID == languageID)
        }
    }

    @Test func theStdioServersAskForStdio() throws {
        for languageID in ["typescript", "javascript", "vue", "python", "json", "yaml"] {
            let definition = try #require(LSPServerRegistry.server(forLanguage: languageID))
            #expect(definition.arguments.contains("--stdio"), "\(languageID) does not request stdio")
        }
    }

    @Test func typeScriptAndJavaScriptShareOneServer() throws {
        let typescript = try #require(LSPServerRegistry.server(forLanguage: "typescript"))
        let javascript = try #require(LSPServerRegistry.server(forLanguage: "javascript"))
        let react = try #require(LSPServerRegistry.server(forLanguage: "typescriptreact"))

        #expect(typescript.command == "typescript-language-server")
        #expect(javascript.command == typescript.command)
        #expect(react.command == typescript.command)
        #expect(javascript.installHint == typescript.installHint)
    }

    /// Language ids are matched case-insensitively because they arrive from
    /// configuration and from file-type detection, neither of which agrees
    /// on casing.
    @Test func languageLookupIgnoresCase() {
        #expect(LSPServerRegistry.server(forLanguage: "Swift")?.command == "sourcekit-lsp")
        #expect(LSPServerRegistry.server(forLanguage: "TypeScript")?.languageID == "typescript")
    }

    @Test func pathsMapToTheirLanguage() {
        #expect(LSPServerRegistry.languageID(forPath: "/tmp/a/index.ts") == "typescript")
        #expect(LSPServerRegistry.languageID(forPath: "App.tsx") == "typescriptreact")
        #expect(LSPServerRegistry.languageID(forPath: "/x/HomeView.vue") == "vue")
        #expect(LSPServerRegistry.languageID(forPath: "GitStatus.SWIFT") == "swift")
        #expect(LSPServerRegistry.languageID(forPath: "build.zig") == "zig")
        #expect(LSPServerRegistry.languageID(forPath: "docker-compose.yml") == "yaml")
    }

    /// Most files a terminal opens have no language server, and that is the
    /// normal case rather than a failure.
    @Test func pathsWithNoKnownLanguageResolveToNothing() {
        #expect(LSPServerRegistry.languageID(forPath: "README.md") == nil)
        #expect(LSPServerRegistry.languageID(forPath: "Makefile") == nil)
        #expect(LSPServerRegistry.languageID(forPath: "/etc/hosts") == nil)
        #expect(LSPServerRegistry.server(forPath: "notes.txt") == nil)
    }

    @Test func aPathResolvesAllTheWayToItsServer() throws {
        let definition = try #require(LSPServerRegistry.server(forPath: "src/main.rs"))

        #expect(definition.command == "rust-analyzer")
        #expect(definition.installHint == "rustup component add rust-analyzer")
    }

    /// The list an "install these" UI would show: one row per binary, not
    /// one per language id.
    @Test func distinctServersCollapseSharedBinaries() {
        let commands = LSPServerRegistry.distinctServers.map(\.command)

        #expect(Set(commands).count == commands.count)
        #expect(commands.filter { $0 == "typescript-language-server" }.count == 1)
        #expect(commands.count < LSPServerRegistry.all.count)
    }

    @Test func invocationReadsAsACommandLine() throws {
        let typescript = try #require(LSPServerRegistry.server(forLanguage: "typescript"))
        let swift = try #require(LSPServerRegistry.server(forLanguage: "swift"))

        #expect(typescript.invocation == "typescript-language-server --stdio")
        #expect(swift.invocation == "sourcekit-lsp")
    }
}
