import Foundation
import Testing
@testable import Ghostty

struct SSHSessionFileTests {
    @Test func persistsWithPrivatePermissionsAndDetectsConflicts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SSHSessionFile(url: directory.appendingPathComponent("sessions.json"))
        #expect(try file.load().profiles.isEmpty)
        let doc = SSHSessionDocument(profiles: [SSHProfile(name: "Test", destination: "server")])
        try file.save(doc)
        #expect(try file.load() == doc)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let other = SSHSessionFile(url: file.url)
        _ = try other.load()
        try file.save(SSHSessionDocument())
        #expect(throws: (any Error).self) { try other.save(doc) }
    }

    @Test func neverOverwritesNewerOrCorruptDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for content in ["broken", "{\"schemaVersion\":99,\"folders\":[],\"profiles\":[]}"] {
            let url = directory.appendingPathComponent("sessions.json")
            let data = Data(content.utf8)
            try data.write(to: url)
            let file = SSHSessionFile(url: url)
            #expect(throws: (any Error).self) { try file.load() }
            #expect(throws: (any Error).self) { try file.save(SSHSessionDocument()) }
            #expect(try Data(contentsOf: url) == data)
        }
    }
}
