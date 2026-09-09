import Foundation
import Testing
@testable import Ghostty

struct QuickCommandTests {
    @Test func literalBytesAndExecution() throws {
        let command = QuickCommand(title: "Unicode", command: "é \\\"", action: .execute)
        #expect(command.bindingAction(execute: false) == "text:\\xc3\\xa9\\x20\\x5c\\x22")
        #expect(command.bindingAction(execute: true) == "text:\\xc3\\xa9\\x20\\x5c\\x22\\x0d")
        #expect(QuickCommand(title: "Insert only", command: "echo ok").bindingAction(execute: true) == nil)
    }

    @Test func validationAndDuplicate() {
        for text in ["", "  ", "echo\nexit", "echo\rexit", "echo\t", "\0", "\u{1b}", "\u{7f}"] {
            let command = QuickCommand(title: "Invalid", command: text, action: .execute)
            #expect(command.bindingAction(execute: false) == nil)
            #expect(command.bindingAction(execute: true) == nil)
        }
        #expect(QuickCommand(title: " ", command: "echo ok").validationError != nil)
        let command = QuickCommand(title: "Preparar 👻", command: " git commit -m \"\" ", group: "Git")
        #expect(command.validationError == nil)
        #expect(command.group == "Git")
        let copy = command.duplicate()
        #expect(copy.id != command.id)
        #expect(copy.command == command.command)
        #expect(copy.title == command.title)
        #expect(copy.action == command.action)
        #expect(copy.group == command.group)

        // Test placeholders & resolvedCommand
        let parametrized = QuickCommand(title: "SSH", command: "ssh <user>@{host} -p <port>")
        #expect(parametrized.placeholders == ["user", "host", "port"])
        let resolved = parametrized.resolvedCommand(with: ["user": "admin", "host": "192.168.1.1", "port": "22"])
        #expect(resolved == "ssh admin@192.168.1.1 -p 22")

        // Test smart placeholders (clipboard, selection)
        let smartCmd = QuickCommand(title: "Smart", command: "echo {clipboard} <selection> <target>")
        #expect(smartCmd.placeholders == ["clipboard", "selection", "target"])
        #expect(smartCmd.manualPlaceholders == ["target"])
        let autoResolved = smartCmd.autoResolvedCommand(clipboard: "hello", selection: "world", values: ["target": "done"])
        #expect(autoResolved == "echo hello world done")
    }

    @MainActor @Test func libraryRoundtripAndEditing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("commands.json")
        let library = QuickCommandLibrary(url: url)
        #expect(library.commands.isEmpty)
        #expect(library.canWrite)
        var command = QuickCommand(title: "Pruebas 👻", command: "echo \\n", action: .execute)
        #expect(library.save(command))
        command.command = "git commit -m \"\""
        #expect(library.save(command))
        let loaded = QuickCommandLibrary(url: url)
        #expect(loaded.commands == [command])
        let duplicate = command.duplicate()
        #expect(loaded.save(duplicate))
        #expect(loaded.delete(command))
        #expect(QuickCommandLibrary(url: url).commands == [duplicate])
    }

    @MainActor @Test func corruptLibraryIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("commands.json")
        let invalid = Data("broken json".utf8)
        try invalid.write(to: url)
        let library = QuickCommandLibrary(url: url)
        #expect(!library.canWrite)
        #expect(library.errorMessage != nil)
        #expect(!library.save(QuickCommand(title: "Test", command: "echo ok")))
        #expect(try Data(contentsOf: url) == invalid)
        let valid = try JSONEncoder().encode(QuickCommandLibrary.Document(commands: []))
        try valid.write(to: url)
        library.reload()
        #expect(library.canWrite)
        #expect(library.errorMessage == nil)
    }

    @MainActor @Test func failedWritePreservesMemoryAndDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("commands.json")
        let library = QuickCommandLibrary(url: url)
        let command = QuickCommand(title: "First", command: "echo first")
        #expect(library.save(command))
        let previous = try Data(contentsOf: url)
        // Replace the destination with a directory to force a deterministic write failure.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let marker = url.appendingPathComponent("original.json")
        try previous.write(to: marker)
        #expect(!library.save(command.duplicate()))
        #expect(library.commands == [command])
        #expect(library.errorMessage != nil)
        #expect(try Data(contentsOf: marker) == previous)
    }

    @MainActor @Test func invalidDocumentsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("commands.json")
        let command = QuickCommand(title: "Test", command: "echo ok")
        let documents = [
            QuickCommandLibrary.Document(version: 2, commands: []),
            QuickCommandLibrary.Document(commands: [command, command]),
            QuickCommandLibrary.Document(commands: [QuickCommand(title: "Test", command: "\n")])
        ]
        for document in documents {
            try JSONEncoder().encode(document).write(to: url)
            let library = QuickCommandLibrary(url: url)
            #expect(!library.canWrite)
            #expect(library.commands.isEmpty)
        }
    }
}
