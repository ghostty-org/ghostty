import Foundation

/// OSC 7501 belongs to the terminal client, including clients whose Agent runs
/// in a shared server. It therefore needs neither a Hook PID nor a daemon TTY.
struct AgentProgramStatus {
    struct Record {
        let id: String
        let agent: SupportedAgent?
        let state: TabActivityState
        let attention: TabAttentionKind?
        let message: String?
        let progress: Double?
        var acknowledged = false

        var activity: TabActivity? {
            guard let agent else { return nil }
            return .init(source: agent.rawValue, state: acknowledged ? .idle : state,
                         attentionKind: acknowledged ? nil : attention,
                         label: agent.displayName, message: acknowledged ? nil : message, detail: nil,
                         progress: acknowledged ? nil : progress, icon: agent.icon)
        }
    }

    private(set) var records: [Record] = []
    var isRemote = false
    var foregroundProcessGroup: Int?
    var activity: TabActivity? { records.last?.activity }

    /// Core validates the full protocol. Retain bounded validation here too:
    /// OSC 3008 shares the bridge and terminal text is never trusted authority.
    mutating func consume(_ body: String) -> Bool {
        guard body.utf8.count <= 4087 else { return false }
        var fields: [String: String] = [:]
        for pair in body.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.utf8.count <= 16 else { return false }
            if key == "id", !Self.validID(value) { return false }
            if key == "app", value.utf8.count > 32 { return false }
            if key == "msg", Self.text(value, limit: 2048) == nil { return false }
            if key == "title", Self.text(value, limit: 192) == nil { return false }
            fields[key] = value
        }
        let id = fields["id"] ?? ""
        if fields["state"] == "clear" {
            records.removeAll { id.isEmpty || $0.id == id || $0.id.hasPrefix(id + "/") }
            return true
        }
        let state: TabActivityState
        switch fields["state"] {
        case "idle": state = .idle
        case "working": state = .working
        case "done": state = .done
        case "blocked": state = .needsAttention
        case "error": state = .error
        default: return false
        }
        let progress = fields["progress"].flatMap { raw -> Double? in
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Double(raw), (0...100).contains(value) else { return nil }
            return value / 100
        }
        let attention: TabAttentionKind? = if state == .needsAttention {
            fields["kind"] == "question" ? .question : (fields["kind"] == "permission" ? .permission : nil)
        } else { nil }
        let agent = fields["app"].flatMap(SupportedAgent.init(rawValue:))
        let acknowledged = records.first { $0.id == id }.map {
            $0.acknowledged && $0.agent == agent && $0.state == state
        } ?? false
        records.removeAll { $0.id == id }
        if records.count >= 32 { records.removeFirst() }
        records.append(.init(id: id, agent: agent,
            state: state, attention: attention,
            message: fields["msg"].flatMap { Self.text($0, limit: 2048) },
            progress: state == .working || state == .needsAttention ? progress : nil,
            acknowledged: acknowledged))
        return true
    }

    mutating func acknowledge() -> Bool {
        guard let last = records.indices.last,
              !records[last].acknowledged,
              records[last].state == .done || records[last].state == .error else { return false }
        records[last].acknowledged = true
        return true
    }

    private static func validID(_ value: String) -> Bool {
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-".utf8)
        return value.utf8.count <= 128 && segments.count <= 8 &&
            segments.allSatisfy { !$0.isEmpty && $0.utf8.count <= 32 && $0.utf8.allSatisfy(alphabet.contains) }
    }

    private static func text(_ value: String, limit: Int) -> String? {
        guard value.utf8.count <= ((limit + 2) / 3) * 4 else { return nil }
        let padded = value + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= limit,
              let text = String(data: data, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value > 31 && !(127...159).contains($0.value) }) else { return nil }
        return text
    }
}
