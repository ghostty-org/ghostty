import Foundation
import Testing
@testable import Ghostty

struct SSHProfileTests {
    @Test func rejectsInvalidDestinations() throws {
        for destination in ["", "-oProxyCommand=touch", "host name", "host\nname", "user@host", "host;touch"] {
            var profile = SSHProfile()
            profile.name = "Test"
            profile.destination = destination
            #expect(throws: (any Error).self) { try profile.validate() }
        }
    }

    @Test func validatesPortsAndCertificateFiles() throws {
        var profile = SSHProfile(name: "Server", destination: "server.example")
        profile.port = 0
        #expect(throws: (any Error).self) { try profile.validate() }
        profile.port = 65536
        #expect(throws: (any Error).self) { try profile.validate() }
        profile.port = 22
        profile.authentication = .certificate
        #expect(throws: (any Error).self) { try profile.validate() }
        profile.identityFile = "/tmp/key with ' quotes"
        profile.certificateFile = "/tmp/key-cert.pub"
        try profile.validate()
        let args = try SSHInvocation.arguments(for: profile)
        #expect(args.contains(profile.identityFile))
        #expect(args.contains("CertificateFile=\"/tmp/key-cert.pub\""))
        #expect(args.last == "server.example")
        #expect(args.contains("PreferredAuthentications=publickey"))
    }

    @Test func passwordOnlyAndNoSecretInArguments() throws {
        var profile = SSHProfile(name: "Server", destination: "::1")
        profile.authentication = .password
        profile.username = "user"
        profile.port = 2222
        let args = try SSHInvocation.arguments(for: profile)
        #expect(args.contains("PreferredAuthentications=password"))
        #expect(!args.contains(where: { $0.contains("keyboard-interactive") }))
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.contains("ControlMaster=no"))
        #expect(args.contains("ControlPath=none"))
        let manual = try SSHInvocation.arguments(for: profile, manual: true)
        #expect(manual.contains("PreferredAuthentications=keyboard-interactive,password"))
    }

    @Test func documentRoundTripsWithoutSecrets() throws {
        let profile = SSHProfile(name: "Prod", destination: "prod")
        let document = SSHSessionDocument(profiles: [profile])
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(SSHSessionDocument.self, from: data) == document)
        #expect(!String(decoding: data, as: UTF8.self).contains("passwordValue"))
    }

    @Test func shellQuotingPreservesApostrophes() {
        #expect(SSHInvocation.shellQuote("/App's/Ghostty") == "'/App'\\''s/Ghostty'")
    }
}
