import Testing
@testable import Ghostty

struct QuickCommandConfigTests {
    @Test func configuredCommandsAndReload() throws {
        let config = try TemporaryConfig("""
        quick-command = title:"Preparar 👻",command:"git commit -m \\"\\""
        quick-command = title:Pruebas,command:zig build test,action:execute
        """)
        #expect(config.quickCommands.count == 2)
        let copied = config.quickCommands
        #expect(copied.first?.command == "git commit -m \"\"")
        #expect(copied.first?.action == .insert)
        #expect(copied.last?.action == .execute)
        try config.reload("quick-command =")
        #expect(config.quickCommands.isEmpty)
        #expect(copied.first?.title == "Preparar 👻")
    }

    @Test func invalidEntryProducesDiagnostic() throws {
        let config = try TemporaryConfig("quick-command = title:Bad,command:echo ok,action:unknown")
        #expect(config.quickCommands.isEmpty)
        #expect(config.errors.contains { $0.contains("quick-command") })
    }
}
