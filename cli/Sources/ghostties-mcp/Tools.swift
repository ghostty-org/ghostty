import Foundation
import GhosttiesCore

/// One MCP tool — name, description, JSON-Schema for its inputs, and a handler.
struct Tool {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let handler: (_ args: JSONValue, _ resolver: TasksDirectoryResolver) -> ToolResult
}

/// Result of a tool call. On success, `content` carries the payload as MCP
/// content blocks (we use a single text block whose text is JSON). On error,
/// `isError = true` and `content` carries a human-readable message per spec.
struct ToolResult {
    let content: [JSONValue]
    let isError: Bool

    static func text(_ s: String) -> ToolResult {
        ToolResult(
            content: [.object(["type": .string("text"), "text": .string(s)])],
            isError: false
        )
    }

    /// Encode an object as JSON text and wrap it in a single text content block.
    /// MCP does not yet have a well-supported structured result type across
    /// clients — JSON-in-text is the safest lowest common denominator.
    static func json(_ value: JSONValue) -> ToolResult {
        let data = (try? JSONSerialization.data(
            withJSONObject: value.any,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return ToolResult(
            content: [.object(["type": .string("text"), "text": .string(s)])],
            isError: false
        )
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(
            content: [.object(["type": .string("text"), "text": .string(message)])],
            isError: true
        )
    }

    var asJSON: JSONValue {
        .object([
            "content": .array(content),
            "isError": .bool(isError)
        ])
    }
}

// MARK: - Shared helpers

/// Compact task summary used in list-style responses. Matches the shape the
/// Phase 3 spec calls out: id, title, lane, project, source, source_id,
/// priority, branch, updated.
func taskSummary(_ t: Task) -> JSONValue {
    var out: [String: JSONValue] = [
        "id": .string(t.id),
        "title": .string(t.title),
        "lane": .string(t.lane.display),
        "project": t.project.map(JSONValue.string) ?? .null,
        "source": t.source.map(JSONValue.string) ?? .null,
        "source_id": t.sourceID.map(JSONValue.string) ?? .null,
        "branch": t.branch.map(JSONValue.string) ?? .null,
        "project_path": t.projectPath.map(JSONValue.string) ?? .null,
        "template": t.template.map(JSONValue.string) ?? .null
    ]
    // Emit priority as a string using the typed field. `.none` serialises as
    // "none" (not null) so consumers can distinguish "unset" from "no value".
    out["priority"] = .string(t.priority.rawValue)
    // Prefer `updated` frontmatter if set; else `completed`; else `created`.
    let updated = Frontmatter.value(for: "updated", in: t.frontmatter)
        ?? Frontmatter.value(for: "completed", in: t.frontmatter)
        ?? Frontmatter.value(for: "created", in: t.frontmatter)
    out["updated"] = updated.map(JSONValue.string) ?? .null
    return .object(out)
}

/// Full task detail. Adds raw body + extracted `## Notes` section.
func taskDetail(_ t: Task) -> JSONValue {
    var obj: [String: JSONValue]
    if case .object(let o) = taskSummary(t) {
        obj = o
    } else {
        obj = [:]
    }
    obj["notes"] = .string(extractSection(named: "Notes", from: t.body) ?? "")
    obj["body"] = .string(t.body)
    return .object(obj)
}

/// Pull the content of a `## <name>` section out of a markdown body.
/// Returns nil if the section isn't present.
func extractSection(named name: String, from body: String) -> String? {
    let lines = body.components(separatedBy: "\n")
    var start: Int?
    for (i, l) in lines.enumerated() {
        if l.hasPrefix("## "), l.dropFirst(3).trimmingCharacters(in: .whitespaces) == name {
            start = i
            break
        }
    }
    guard let s = start else { return nil }
    var end = lines.count
    for i in (s + 1)..<lines.count {
        if lines[i].hasPrefix("## ") { end = i; break }
    }
    let slice = lines[(s + 1)..<end]
    // Trim leading/trailing blank lines inside the section.
    var arr = Array(slice)
    while let first = arr.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        arr.removeFirst()
    }
    while let last = arr.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        arr.removeLast()
    }
    return arr.joined(separator: "\n")
}

/// ISO-8601 formatter shared across tools. Matches existing fixtures.
let isoTimestamp: () -> String = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return { f.string(from: Date()) }
}()

/// Human-friendly timestamp used for note bullet prefixes. Matches the `gt
/// notes append` format.
let humanStamp: () -> String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return { f.string(from: Date()) }
}()

// MARK: - Schema helpers

/// Small DSL for JSON Schema fragments so tool definitions stay readable.
enum S {
    static func object(properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (k, v) in properties { props[k] = v }
        var obj: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(props)
        ]
        if !required.isEmpty {
            obj["required"] = .array(required.map(JSONValue.string))
        }
        return .object(obj)
    }

    static func string(_ description: String, enum cases: [String]? = nil) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let cases {
            obj["enum"] = .array(cases.map(JSONValue.string))
        }
        return .object(obj)
    }
}

/// All 9 lanes accepted as status-ish strings. Spec says `graveyard` is an
/// alias for `done`.
let laneEnum = ["inbox", "backlog", "running", "needs-you", "review", "done", "graveyard"]
let priorityEnum = ["high", "medium", "low", "none"]

// MARK: - Tools

func allTools() -> [Tool] {
    [
        listTasksTool(),
        getTaskTool(),
        createTaskTool(),
        updateTaskStatusTool(),
        getActiveTool(),
        getNeedsYouTool(),
        readTaskNotesTool(),
        appendTaskNotesTool(),
        writeSessionNotesTool(),
        getInboxTool(),
        setTaskProjectTool()
    ]
}
