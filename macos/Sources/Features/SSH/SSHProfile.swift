import Foundation

struct SSHProfile: Codable, Identifiable, Equatable {
    enum Authentication: String, Codable, CaseIterable, Identifiable {
        case configuration, password, privateKey, certificate
        var id: Self { self }
        var title: String {
            switch self {
            case .configuration: return "SSH Configuration"
            case .password: return "Password"
            case .privateKey: return "Private Key"
            case .certificate: return "Private Key + OpenSSH Certificate"
            }
        }
    }

    enum TerminalType: String, Codable, CaseIterable, Identifiable {
        case xterm256 = "xterm-256color", xterm, linux, vt100, vt220, ansi
        case screen256 = "screen-256color", screen, tmux256 = "tmux-256color"
        case ghostty = "xterm-ghostty", inherited = "inherit"
        var id: Self { self }
        var title: String { self == .inherited ? "Inherit local terminal" : rawValue }
    }

    enum Encoding: String, Codable, CaseIterable, Identifiable {
        case utf8 = "UTF-8", eucKR = "EUC-KR", cp949 = "CP949"
        case shiftJIS = "SHIFT_JIS", eucJP = "EUC-JP"
        case gb18030 = "GB18030", gbk = "GBK", big5 = "BIG5"
        case latin1 = "ISO-8859-1", latin9 = "ISO-8859-15", windows1252 = "WINDOWS-1252"
        case windows1251 = "WINDOWS-1251", koi8R = "KOI8-R"
        var id: Self { self }
        var title: String {
            switch self {
            case .utf8: return "UTF-8 (Unicode)"
            case .eucKR: return "EUC-KR (Korean)"
            case .cp949: return "CP949 (Korean / Windows)"
            case .shiftJIS: return "Shift JIS (Japanese)"
            case .eucJP: return "EUC-JP (Japanese)"
            case .gb18030: return "GB18030 (Simplified Chinese)"
            case .gbk: return "GBK (Simplified Chinese)"
            case .big5: return "Big5 (Traditional Chinese)"
            case .latin1: return "ISO-8859-1 (Western European)"
            case .latin9: return "ISO-8859-15 (Western European)"
            case .windows1252: return "Windows-1252 (Western European)"
            case .windows1251: return "Windows-1251 (Cyrillic)"
            case .koi8R: return "KOI8-R (Cyrillic)"
            }
        }
    }

    var id = UUID()
    var name = ""
    var folderID: UUID?
    var favorite = false
    var destination = ""
    var username = ""
    var port: Int?
    var authentication: Authentication = .password
    var terminalType: TerminalType = .xterm256
    var encoding: Encoding = .utf8
    var identityFile = ""
    var certificateFile = ""
    var passwordID: UUID?
    var passphraseID: UUID?

    init(name: String = "", destination: String = "") {
        self.name = name
        self.destination = destination
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderID, favorite, destination, username, port, authentication
        case identityFile, certificateFile, passwordID, passphraseID, terminalType, encoding
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        destination = try values.decode(String.self, forKey: .destination)
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port)
        // Keep the auth method of older saved profiles; only new profiles default to password.
        authentication = try values.decodeIfPresent(Authentication.self, forKey: .authentication) ?? .configuration
        identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        certificateFile = try values.decodeIfPresent(String.self, forKey: .certificateFile) ?? ""
        passwordID = try values.decodeIfPresent(UUID.self, forKey: .passwordID)
        passphraseID = try values.decodeIfPresent(UUID.self, forKey: .passphraseID)
        terminalType = try values.decodeIfPresent(TerminalType.self, forKey: .terminalType) ?? .xterm256
        encoding = try values.decodeIfPresent(Encoding.self, forKey: .encoding) ?? .utf8
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SSHError.message("Enter a connection name.")
        }
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:%")
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              destination.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) else {
            throw SSHError.message("Enter a hostname, IP address, or SSH alias without a user or port.")
        }
        let userCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !username.hasPrefix("-"), username.unicodeScalars.allSatisfy({ userCharacters.contains($0) }) else {
            throw SSHError.message("The username contains unsupported characters.")
        }
        if let port, !(1...65535).contains(port) { throw SSHError.message("Port must be between 1 and 65535.") }
        if authentication == .privateKey || authentication == .certificate {
            guard identityFile.hasPrefix("/"), !identityFile.contains("\n"), !identityFile.contains("\0") else {
                throw SSHError.message("Choose an absolute private key path.")
            }
        }
        if authentication == .certificate {
            guard certificateFile.hasPrefix("/"), !certificateFile.contains("\n"), !certificateFile.contains("\0") else {
                throw SSHError.message("Choose an absolute OpenSSH certificate path.")
            }
        }
    }
}

struct SSHFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}

struct SSHSessionDocument: Codable, Equatable {
    var schemaVersion = 1
    var folders: [SSHFolder] = []
    var profiles: [SSHProfile] = []
}

enum SSHError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum SSHInvocation {
    static func arguments(for profile: SSHProfile, manual: Bool = false) throws -> [String] {
        try profile.validate()
        // Keep the session in this PTY and prevent reuse of an already-authenticated master.
        var args = ["-o", "StrictHostKeyChecking=ask", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    "-o", "ForkAfterAuthentication=no", "-o", "PermitLocalCommand=no", "-o", "NumberOfPasswordPrompts=1"]
        if !profile.username.isEmpty { args += ["-l", profile.username] }
        if let port = profile.port { args += ["-p", String(port)] }
        switch profile.authentication {
        case .configuration: break
        case .password:
            args += ["-o", manual ? "PreferredAuthentications=keyboard-interactive,password" : "PreferredAuthentications=password"]
        case .privateKey, .certificate:
            args += ["-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes", "-i", profile.identityFile]
            if profile.authentication == .certificate {
                args += ["-o", "CertificateFile=\"\(configQuote(profile.certificateFile))\""]
            }
        }
        return args + ["--", profile.destination]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func configQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Stored alongside the value inside Keychain, binding a secret to its original connection.
struct SSHCredentialContext: Codable, Equatable {
    var destination: String
    var username: String
    var port: Int?
    var authentication: SSHProfile.Authentication
    var identityFile: String
    var certificateFile: String

    init(_ profile: SSHProfile) {
        destination = profile.destination
        username = profile.username
        port = profile.port
        authentication = profile.authentication
        identityFile = profile.identityFile
        certificateFile = profile.certificateFile
    }
}
