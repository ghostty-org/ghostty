import Foundation
import Testing
@testable import Ghostty

struct SSHAuthenticationTests {
    @Test func matchesOnlyExpectedPasswordPrompt() {
        var profile = SSHProfile(name: "Server", destination: "server")
        profile.authentication = .password
        let policy = SSHAuthenticationPolicy(profile: profile, hostname: "server.example", username: "alice", hasProxy: false)
        #expect(policy.credential(for: "alice@server.example's password: ") == .password)
        #expect(policy.credential(for: "root@server.example's password: ") == nil)
        #expect(policy.credential(for: "alice@jump's password: ") == nil)
        #expect(policy.credential(for: "Verification code: ") == nil)
        #expect(policy.credential(for: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ") == nil)
    }

    @Test func proxyNeverUsesSavedSecrets() {
        var profile = SSHProfile(name: "Server", destination: "server")
        profile.authentication = .password
        let policy = SSHAuthenticationPolicy(profile: profile, hostname: "server", username: "alice", hasProxy: true)
        #expect(policy.credential(for: "alice@server's password: ") == nil)
    }

    @Test func keyPassphraseIsBoundToSelectedKey() {
        var profile = SSHProfile(name: "Server", destination: "server")
        profile.authentication = .certificate
        profile.identityFile = "/tmp/my key"
        let policy = SSHAuthenticationPolicy(profile: profile, hostname: "server", username: "alice", hasProxy: false)
        #expect(policy.credential(for: "Enter passphrase for key '/tmp/my key': ") == .passphrase)
        #expect(policy.credential(for: "Enter passphrase for key '/tmp/other': ") == nil)
        #expect(policy.credential(for: "alice@server's password: ") == nil)
    }
}

struct SSHCredentialContextTests {
    @Test func bindsSecretsToConnectionButNotDisplayName() {
        var profile = SSHProfile(name: "Server", destination: "server")
        let original = SSHCredentialContext(profile)
        profile.name = "Renamed"
        profile.favorite = true
        #expect(SSHCredentialContext(profile) == original)
        profile.destination = "other"
        #expect(SSHCredentialContext(profile) != original)
        profile.destination = "server"
        profile.username = "other-user"
        #expect(SSHCredentialContext(profile) != original)
        profile.username = ""
        profile.port = 2222
        #expect(SSHCredentialContext(profile) != original)
    }

    @Test func savedSecretClaimsAreSingleUseAndIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #expect(SSHAuthenticationPolicy.claim(.password, directory: first))
        #expect(!SSHAuthenticationPolicy.claim(.password, directory: first))
        #expect(SSHAuthenticationPolicy.claim(.password, directory: second))
        #expect(SSHAuthenticationPolicy.claim(.passphrase, directory: first))
    }
}
