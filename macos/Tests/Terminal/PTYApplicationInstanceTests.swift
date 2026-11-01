import Foundation
import Testing
@testable import Ghostty

struct PTYApplicationInstanceTests {
    @Test func onlyOneOwnerCanLoadAndSaveTheRestorationProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: PTYApplicationInstance? = try .init(directory: directory)
        #expect(first != nil)
        #expect(throws: PTYApplicationInstance.Failure.self) {
            try PTYApplicationInstance(directory: directory)
        }
        first = nil
        let replacement = try PTYApplicationInstance(directory: directory)
        _ = withExtendedLifetime(replacement) {
            #expect(throws: PTYApplicationInstance.Failure.self) {
                try PTYApplicationInstance(directory: directory)
            }
        }
    }

    @Test func independentProfilesDoNotBlockEachOther() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try PTYApplicationInstance(directory: directory.appendingPathComponent("first"))
        let second = try PTYApplicationInstance(directory: directory.appendingPathComponent("second"))
        withExtendedLifetime((first, second)) {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("second/gui-instance.lock").path))
        }
    }
}
