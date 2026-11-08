import Darwin
import Foundation

struct SSHAuthenticationPolicy: Codable {
    enum Credential: String, Codable { case password, passphrase }
    var profile: SSHProfile
    var hostname: String
    var username: String
    var hasProxy: Bool

    static func claim(_ kind: Credential, directory: URL) -> Bool {
        let descriptor = open(directory.appendingPathComponent("used-\(kind.rawValue)").path,
                              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    func credential(for prompt: String) -> Credential? {
        guard !hasProxy else { return nil }
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch profile.authentication {
        case .password:
            return request == "\(username)@\(hostname)'s password:" ? .password : nil
        case .privateKey, .certificate:
            return request == "Enter passphrase for key '\(profile.identityFile)':" ? .passphrase : nil
        case .configuration: return nil
        }
    }
}
