import Foundation
import Testing
@testable import Ghostty

struct SSHConfigurationCatalogTests {
    @Test func aliasesIncludeQuotedGlobFilesAndDeduplicateConcreteHosts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let include = root.appendingPathComponent("conf dir")
        try FileManager.default.createDirectory(at: include, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        try "Host cloud cloud\nInclude \"conf dir/*.conf\"\nHost * !excluded *.example.com\n".write(to: config, atomically: true, encoding: .utf8)
        try "Host=vps-jump\nHost \"without-hostname\" # comment\nInclude config\n".write(
            to: include.appendingPathComponent("extra.conf"), atomically: true, encoding: .utf8)
        #expect(SSHConfigurationCatalog.aliases(at: config, relativeRoot: root) == ["cloud", "vps-jump", "without-hostname"])
    }

    @Test func configHostsResolveCompleteEndpointsWithoutAnActiveConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        try "Host cloud cloud-alt\n HostName 10.0.0.123\n User chengjisheng\n Port 2222\n".write(to: config, atomically: true, encoding: .utf8)
        let choices = await SSHConfigurationCatalog.choices(live: [], file: config)
        #expect(choices.count == 2)
        #expect(choices.allSatisfy { $0.endpoint == "chengjisheng@10.0.0.123:2222" && $0.fromConfiguration })
        #expect(choices.contains { $0.title == "cloud · chengjisheng@10.0.0.123:2222" })
    }
}
