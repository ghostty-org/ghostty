const std = @import("std");

const Allocator = std.mem.Allocator;
const JsonArray = std.json.Array;
const JsonObject = std.json.ObjectMap;
const JsonValue = std.json.Value;

const codex_events = [_]HookEvent{
    .{ .agent_event = "SessionStart", .helper_event = "session-start", .label = "session_start" },
    .{ .agent_event = "UserPromptSubmit", .helper_event = "prompt-submit", .label = "user_prompt_submit" },
    .{ .agent_event = "Stop", .helper_event = "stop", .label = "stop" },
    .{ .agent_event = "PreToolUse", .helper_event = "pre-tool-use", .label = "pre_tool_use" },
    .{ .agent_event = "PermissionRequest", .helper_event = "permission-request", .label = "permission_request" },
};

const HookEvent = struct {
    agent_event: []const u8,
    helper_event: []const u8,
    label: []const u8,
};

const HookInput = struct {
    session_id: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    hook_event_name: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,

    fn deinit(self: HookInput, alloc: Allocator) void {
        if (self.session_id) |v| alloc.free(v);
        if (self.turn_id) |v| alloc.free(v);
        if (self.cwd) |v| alloc.free(v);
        if (self.transcript_path) |v| alloc.free(v);
        if (self.hook_event_name) |v| alloc.free(v);
        if (self.tool_name) |v| alloc.free(v);
    }
};

const NormalizedState = enum {
    idle,
    running,
    needs_input,
    errored,

    fn jsonValue(self: NormalizedState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .needs_input => "needsInput",
            .errored => "error",
        };
    }

    fn statusValue(self: NormalizedState) []const u8 {
        return switch (self) {
            .idle => "Idle",
            .running => "Running",
            .needs_input => "Needs input",
            .errored => "Error",
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len >= 3 and std.mem.eql(u8, args[1], "install")) {
        if (std.mem.eql(u8, args[2], "codex")) {
            try installCodexHooks(alloc);
            return;
        }
        return error.UnsupportedAgent;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "uninstall")) {
        if (std.mem.eql(u8, args[2], "codex")) {
            try uninstallCodexHooks(alloc);
            return;
        }
        return error.UnsupportedAgent;
    }

    defer writeEmptyHookOutput() catch {};

    if (args.len < 3) return;
    emitHookEvent(alloc, args[1], args[2]) catch {};
}

fn writeEmptyHookOutput() !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try stdout.interface.writeAll("{}\n");
    try stdout.interface.flush();
}

fn emitHookEvent(alloc: Allocator, agent: []const u8, event_name: []const u8) !void {
    const event_file = try envOwned(alloc, "GHOSTTY_AGENT_EVENT_FILE") orelse return;
    defer alloc.free(event_file);

    const surface_id = try envOwned(alloc, "GHOSTTY_AGENT_SURFACE_ID") orelse return;
    defer alloc.free(surface_id);

    const state = normalizeState(event_name, null) orelse return;
    const stdin = std.fs.File.stdin().readToEndAlloc(alloc, 1024 * 1024) catch null;
    defer if (stdin) |bytes| alloc.free(bytes);

    const input = parseHookInput(alloc, stdin orelse "") catch HookInput{};
    defer input.deinit(alloc);
    const final_state = normalizeState(event_name, input.tool_name) orelse state;

    var out: std.io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };

    try json.beginObject();
    try json.objectField("version");
    try json.write(@as(u8, 1));
    try json.objectField("surface_id");
    try json.write(surface_id);
    try json.objectField("agent");
    try json.write(agent);
    try json.objectField("event");
    try json.write(event_name);
    try json.objectField("state");
    try json.write(final_state.jsonValue());
    try json.objectField("status_title");
    try json.write(agentDisplayName(agent));
    try json.objectField("status_value");
    try json.write(final_state.statusValue());

    try writeOptionalStringField(&json, "session_id", input.session_id);
    try writeOptionalStringField(&json, "turn_id", input.turn_id);
    try writeOptionalStringField(&json, "cwd", input.cwd);
    try writeOptionalStringField(&json, "transcript_path", input.transcript_path);
    try writeOptionalStringField(&json, "hook_event_name", input.hook_event_name);

    if (try envOwned(alloc, "GHOSTTY_AGENT_PID")) |pid_raw| {
        defer alloc.free(pid_raw);
        if (std.fmt.parseInt(i64, std.mem.trim(u8, pid_raw, &std.ascii.whitespace), 10)) |pid| {
            try json.objectField("pid");
            try json.write(pid);
        } else |_| {}
    }

    const timestamp_ms = std.time.milliTimestamp();
    try json.objectField("timestamp");
    try json.write(@as(f64, @floatFromInt(timestamp_ms)) / 1000.0);
    try json.endObject();

    try appendLine(event_file, out.written());
}

fn writeOptionalStringField(json: *std.json.Stringify, key: []const u8, value: ?[]const u8) !void {
    const raw = value orelse return;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    try json.objectField(key);
    try json.write(trimmed);
}

fn parseHookInput(alloc: Allocator, bytes: []const u8) !HookInput {
    if (std.mem.trim(u8, bytes, &std.ascii.whitespace).len == 0) return .{};

    const parsed = try std.json.parseFromSlice(JsonValue, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    const object = parsed.value.object;
    return .{
        .session_id = try dupeField(alloc, object, &.{ "session_id", "sessionId" }),
        .turn_id = try dupeField(alloc, object, &.{ "turn_id", "turnId" }),
        .cwd = try dupeField(alloc, object, &.{"cwd"}),
        .transcript_path = try dupeField(alloc, object, &.{ "transcript_path", "transcriptPath" }),
        .hook_event_name = try dupeField(alloc, object, &.{ "hook_event_name", "hookEventName" }),
        .tool_name = try dupeField(alloc, object, &.{ "tool_name", "toolName", "name" }),
    };
}

fn dupeField(alloc: Allocator, object: JsonObject, names: []const []const u8) !?[]const u8 {
    const value = stringField(object, names) orelse return null;
    return try alloc.dupe(u8, value);
}

fn stringField(object: JsonObject, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        switch (value) {
            .string => |s| return s,
            else => {},
        }
    }
    return null;
}

fn normalizeState(event_name: []const u8, tool_name: ?[]const u8) ?NormalizedState {
    if (eventNameMatches(event_name, "pre-tool-use")) {
        if (tool_name) |tool| {
            if (std.ascii.eqlIgnoreCase(tool, "AskUserQuestion")) return .needs_input;
        }
    }

    if (eventNameMatches(event_name, "prompt-submit") or
        eventNameMatches(event_name, "user-prompt-submit") or
        eventNameMatches(event_name, "pre-tool-use"))
    {
        return .running;
    }

    if (eventNameMatches(event_name, "notification") or
        eventNameMatches(event_name, "permission-request") or
        eventNameMatches(event_name, "ask-user-question"))
    {
        return .needs_input;
    }

    if (eventNameMatches(event_name, "stop")) {
        return .needs_input;
    }

    if (eventNameMatches(event_name, "session-start") or
        eventNameMatches(event_name, "idle") or
        eventNameMatches(event_name, "session-end"))
    {
        return .idle;
    }

    if (eventNameMatches(event_name, "error") or
        eventNameMatches(event_name, "failure") or
        eventNameMatches(event_name, "failed") or
        eventNameMatches(event_name, "hook-error"))
    {
        return .errored;
    }

    return null;
}

fn eventNameMatches(event_name: []const u8, expected: []const u8) bool {
    const trimmed = std.mem.trim(u8, event_name, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, expected)) return true;

    var buffer: [96]u8 = undefined;
    var len: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c == '_') {
            if (len >= buffer.len) return false;
            buffer[len] = '-';
            len += 1;
            continue;
        }

        if (std.ascii.isUpper(c) and i > 0) {
            if (len >= buffer.len) return false;
            buffer[len] = '-';
            len += 1;
        }

        if (len >= buffer.len) return false;
        buffer[len] = std.ascii.toLower(c);
        len += 1;
    }

    return std.mem.eql(u8, buffer[0..len], expected);
}

fn agentDisplayName(agent: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(agent, "claude")) return "Claude Code";
    if (std.ascii.eqlIgnoreCase(agent, "codex")) return "Codex";
    return agent;
}

fn appendLine(path: []const u8, line: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const fd = try std.posix.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o600);
    var file = std.fs.File{ .handle = fd };
    defer file.close();
    try file.writeAll(line);
    try file.writeAll("\n");
}

fn installCodexHooks(alloc: Allocator) !void {
    const config_dir = try codexConfigDir(alloc);
    defer alloc.free(config_dir);
    try std.fs.cwd().makePath(config_dir);

    const hooks_path = try std.fs.path.join(alloc, &.{ config_dir, "hooks.json" });
    defer alloc.free(hooks_path);
    const config_path = try std.fs.path.join(alloc, &.{ config_dir, "config.toml" });
    defer alloc.free(config_path);

    const hooks_content = try readFileAllocIfExists(alloc, hooks_path);
    defer alloc.free(hooks_content);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var root = try parseHooksRoot(arena_alloc, hooks_content);
    const hooks = try ensureObjectField(arena_alloc, &root.object, "hooks");

    for (&codex_events) |event| {
        try removeOwnedHooksFromEvent(arena_alloc, hooks, event.agent_event);
        try appendCodexHookGroup(arena_alloc, hooks, event);
    }

    const rendered_hooks = try renderJson(alloc, root, .{ .whitespace = .indent_2 });
    defer alloc.free(rendered_hooks);
    try writeFile(hooks_path, rendered_hooks);

    const trust_entries = try codexHookTrustEntries(alloc, hooks, hooks_path);
    defer freeTrustEntries(alloc, trust_entries);

    const config_content = try readFileAllocIfExists(alloc, config_path);
    defer alloc.free(config_content);
    const rendered_config = try codexConfigTomlInstalling(alloc, config_content, trust_entries);
    defer alloc.free(rendered_config);
    try writeFile(config_path, rendered_config);

    try printInstallStatus("Codex hooks installed at ", hooks_path);
}

fn uninstallCodexHooks(alloc: Allocator) !void {
    const config_dir = try codexConfigDir(alloc);
    defer alloc.free(config_dir);

    const hooks_path = try std.fs.path.join(alloc, &.{ config_dir, "hooks.json" });
    defer alloc.free(hooks_path);
    const config_path = try std.fs.path.join(alloc, &.{ config_dir, "config.toml" });
    defer alloc.free(config_path);

    const hooks_content = try readFileAllocIfExists(alloc, hooks_path);
    defer alloc.free(hooks_content);

    if (hooks_content.len > 0) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        var root = try parseHooksRoot(arena_alloc, hooks_content);
        if (root.object.getPtr("hooks")) |hooks_value| {
            if (hooks_value.* == .object) {
                const hooks = &hooks_value.object;
                for (&codex_events) |event| {
                    try removeOwnedHooksFromEvent(arena_alloc, hooks, event.agent_event);
                }
            }
        }
        const rendered_hooks = try renderJson(alloc, root, .{ .whitespace = .indent_2 });
        defer alloc.free(rendered_hooks);
        try writeFile(hooks_path, rendered_hooks);
    }

    const config_content = try readFileAllocIfExists(alloc, config_path);
    defer alloc.free(config_content);
    if (config_content.len > 0) {
        const rendered_config = try codexConfigTomlUninstalling(alloc, config_content);
        defer alloc.free(rendered_config);
        try writeFile(config_path, rendered_config);
    }

    try printInstallStatus("Codex Ghostty hooks removed from ", hooks_path);
}

fn codexConfigDir(alloc: Allocator) ![]const u8 {
    if (try envOwned(alloc, "CODEX_HOME")) |codex_home| return codex_home;
    const home = try envOwned(alloc, "HOME") orelse return error.HomeNotSet;
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, ".codex" });
}

fn parseHooksRoot(alloc: Allocator, content: []const u8) !JsonValue {
    if (std.mem.trim(u8, content, &std.ascii.whitespace).len == 0) {
        return JsonValue{ .object = JsonObject.init(alloc) };
    }

    const parsed = try std.json.parseFromSlice(JsonValue, alloc, content, .{});
    if (parsed.value != .object) return error.InvalidHooksJson;
    return parsed.value;
}

fn ensureObjectField(alloc: Allocator, object: *JsonObject, key: []const u8) !*JsonObject {
    const gop = try object.getOrPut(key);
    if (!gop.found_existing or gop.value_ptr.* != .object) {
        gop.value_ptr.* = JsonValue{ .object = JsonObject.init(alloc) };
    }
    return &gop.value_ptr.object;
}

fn removeOwnedHooksFromEvent(alloc: Allocator, hooks: *JsonObject, event_name: []const u8) !void {
    const value = hooks.getPtr(event_name) orelse return;
    if (value.* != .array) return;

    var rewritten = JsonArray.init(alloc);
    for (value.array.items) |group_value| {
        var group = group_value;
        switch (group) {
            .object => |*group_object| {
                if (group_object.getPtr("hooks")) |hook_list_value| {
                    if (hook_list_value.* == .array) {
                        var hook_list = JsonArray.init(alloc);
                        for (hook_list_value.array.items) |hook_value| {
                            if (!isOwnedHookValue(hook_value)) try hook_list.append(hook_value);
                        }
                        if (hook_list.items.len == 0) continue;
                        hook_list_value.* = JsonValue{ .array = hook_list };
                    }
                } else if (isOwnedHookValue(group)) {
                    continue;
                }
                try rewritten.append(group);
            },
            else => try rewritten.append(group),
        }
    }

    if (rewritten.items.len == 0) {
        _ = hooks.swapRemove(event_name);
    } else {
        value.* = JsonValue{ .array = rewritten };
    }
}

fn isOwnedHookValue(value: JsonValue) bool {
    if (value != .object) return false;
    const command_value = value.object.get("command") orelse return false;
    if (command_value != .string) return false;
    return isOwnedHookCommand(command_value.string);
}

fn isOwnedHookCommand(command: []const u8) bool {
    return std.mem.indexOf(u8, command, "ghostty-agent-hook") != null and
        std.mem.indexOf(u8, command, " codex ") != null;
}

fn appendCodexHookGroup(alloc: Allocator, hooks: *JsonObject, event: HookEvent) !void {
    const gop = try hooks.getOrPut(event.agent_event);
    if (!gop.found_existing or gop.value_ptr.* != .array) {
        gop.value_ptr.* = JsonValue{ .array = JsonArray.init(alloc) };
    }

    var hook_object = JsonObject.init(alloc);
    try hook_object.put("type", JsonValue{ .string = "command" });
    try hook_object.put("command", JsonValue{ .string = try codexHookCommand(alloc, event.helper_event) });
    try hook_object.put("timeout", JsonValue{ .integer = 5000 });

    var hook_list = JsonArray.init(alloc);
    try hook_list.append(JsonValue{ .object = hook_object });

    var group_object = JsonObject.init(alloc);
    try group_object.put("hooks", JsonValue{ .array = hook_list });
    try gop.value_ptr.array.append(JsonValue{ .object = group_object });
}

fn codexHookCommand(alloc: Allocator, event_name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        alloc,
        "ghostty_hook=\"${{GHOSTTY_AGENT_HOOK_HELPER:-$(command -v ghostty-agent-hook 2>/dev/null || true)}}\"; " ++
            "if [ -n \"${{GHOSTTY_AGENT_SURFACE_ID:-}}\" ] && [ -n \"$ghostty_hook\" ]; then " ++
            "GHOSTTY_AGENT_PID=\"${{PPID:-}}\" \"$ghostty_hook\" codex {s}; else printf \"%s\\n\" \"{{}}\"; fi",
        .{event_name},
    );
}

fn renderJson(
    alloc: Allocator,
    value: JsonValue,
    options: std.json.Stringify.Options,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, options, &out.writer);
    try out.writer.writeByte('\n');
    return try alloc.dupe(u8, out.written());
}

const TrustEntry = struct {
    key: []const u8,
    trusted_hash: []const u8,
};

fn codexHookTrustEntries(alloc: Allocator, hooks: *JsonObject, hooks_path: []const u8) ![]TrustEntry {
    const source_path = try normalizedPath(alloc, hooks_path);
    defer alloc.free(source_path);

    var entries = std.ArrayListUnmanaged(TrustEntry).empty;
    for (&codex_events) |event| {
        const groups_value = hooks.get(event.agent_event) orelse continue;
        if (groups_value != .array) continue;

        for (groups_value.array.items, 0..) |group_value, group_index| {
            if (group_value != .object) continue;
            const hooks_value = group_value.object.get("hooks") orelse continue;
            if (hooks_value != .array) continue;

            for (hooks_value.array.items, 0..) |hook_value, hook_index| {
                if (hook_value != .object) continue;
                const command_value = hook_value.object.get("command") orelse continue;
                if (command_value != .string or !isOwnedHookCommand(command_value.string)) continue;
                const timeout_ms = intValue(hook_value.object.get("timeout")) orelse 600;

                const key = try std.fmt.allocPrint(
                    alloc,
                    "{s}:{s}:{d}:{d}",
                    .{ source_path, event.label, group_index, hook_index },
                );
                const trusted_hash = try codexCommandHookHash(
                    alloc,
                    event.label,
                    command_value.string,
                    @intCast(@max(timeout_ms, 1)),
                );
                try entries.append(alloc, .{ .key = key, .trusted_hash = trusted_hash });
            }
        }
    }

    return try entries.toOwnedSlice(alloc);
}

fn freeTrustEntries(alloc: Allocator, entries: []TrustEntry) void {
    for (entries) |entry| {
        alloc.free(entry.key);
        alloc.free(entry.trusted_hash);
    }
    alloc.free(entries);
}

fn codexCommandHookHash(
    alloc: Allocator,
    event_label: []const u8,
    command: []const u8,
    timeout_ms: i64,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"event_name\":");
    try std.json.Stringify.value(event_label, .{}, writer);
    try writer.writeAll(",\"hooks\":[{\"async\":false,\"command\":");
    try std.json.Stringify.value(command, .{}, writer);
    try writer.print(",\"timeout\":{d},\"type\":\"command\"", .{timeout_ms});
    try writer.writeAll("}]}");

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(alloc, "sha256:{s}", .{hex});
}

fn normalizedPath(alloc: Allocator, path: []const u8) ![]const u8 {
    return std.fs.realpathAlloc(alloc, path) catch {
        if (std.fs.path.dirname(path)) |dir| {
            const real_dir = std.fs.realpathAlloc(alloc, dir) catch return try alloc.dupe(u8, path);
            defer alloc.free(real_dir);
            return try std.fs.path.join(alloc, &.{ real_dir, std.fs.path.basename(path) });
        }
        return try alloc.dupe(u8, path);
    };
}

fn intValue(value: ?JsonValue) ?i64 {
    const raw = value orelse return null;
    return switch (raw) {
        .integer => |v| v,
        else => null,
    };
}

const feature_begin = "# ghostty-agent-codex-hooks-feature begin";
const feature_end = "# ghostty-agent-codex-hooks-feature end";
const feature_previous_prefix = "# ghostty-agent-codex-hooks-feature previous line: ";
const trust_begin = "# ghostty-agent-codex-hook-trust begin";
const trust_end = "# ghostty-agent-codex-hook-trust end";

fn codexConfigTomlInstalling(
    alloc: Allocator,
    content: []const u8,
    entries: []const TrustEntry,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const work_alloc = arena.allocator();

    var lines = try tomlLines(work_alloc, content);

    removeMarkedBlock(work_alloc, &lines, feature_begin, feature_end, feature_previous_prefix);
    removeMarkedBlock(work_alloc, &lines, trust_begin, trust_end, null);

    if (!hooksFeatureEnabled(lines.items)) {
        if (findDottedFeaturesHooksIndex(lines.items)) |index| {
            const previous = try std.fmt.allocPrint(work_alloc, "{s}{s}", .{ feature_previous_prefix, lines.items[index] });
            try lines.replaceRange(work_alloc, index, 1, &.{ feature_begin, previous, "features.hooks = true", feature_end });
        } else if (findFeaturesTable(lines.items)) |features| {
            if (findKeyInRange(lines.items, "hooks", features.start + 1, features.end)) |index| {
                const previous = try std.fmt.allocPrint(work_alloc, "{s}{s}", .{ feature_previous_prefix, lines.items[index] });
                try lines.replaceRange(work_alloc, index, 1, &.{ feature_begin, previous, "hooks = true", feature_end });
            } else {
                try lines.insertSlice(work_alloc, features.start + 1, &.{ feature_begin, "hooks = true", feature_end });
            }
        } else {
            if (lines.items.len > 0 and lines.items[lines.items.len - 1].len > 0) {
                try lines.append(work_alloc, "");
            }
            try lines.appendSlice(work_alloc, &.{ "[features]", feature_begin, "hooks = true", feature_end });
        }
    }

    if (entries.len > 0) {
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len > 0) {
            try lines.append(work_alloc, "");
        }
        try lines.append(work_alloc, trust_begin);
        for (entries) |entry| {
            const key = try tomlBasicString(work_alloc, entry.key);
            const hash = try tomlBasicString(work_alloc, entry.trusted_hash);
            try lines.append(work_alloc, try std.fmt.allocPrint(work_alloc, "[hooks.state.\"{s}\"]", .{key}));
            try lines.append(work_alloc, try std.fmt.allocPrint(work_alloc, "trusted_hash = \"{s}\"", .{hash}));
        }
        try lines.append(work_alloc, trust_end);
    }

    const result = try tomlContent(work_alloc, lines.items);
    return try alloc.dupe(u8, result);
}

fn codexConfigTomlUninstalling(alloc: Allocator, content: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const work_alloc = arena.allocator();

    var lines = try tomlLines(work_alloc, content);
    removeMarkedBlock(work_alloc, &lines, feature_begin, feature_end, feature_previous_prefix);
    removeMarkedBlock(work_alloc, &lines, trust_begin, trust_end, null);
    removeEmptyFeaturesTable(work_alloc, &lines);
    const result = try tomlContent(work_alloc, lines.items);
    return try alloc.dupe(u8, result);
}

fn tomlLines(alloc: Allocator, content: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    if (content.len == 0) return lines;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.index == null) break;
        try lines.append(alloc, line);
    }
    return lines;
}

fn tomlContent(alloc: Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return try alloc.dupe(u8, "");
    var out = std.ArrayListUnmanaged(u8).empty;
    for (lines) |line| {
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

fn removeMarkedBlock(
    alloc: Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    begin: []const u8,
    end: []const u8,
    previous_prefix: ?[]const u8,
) void {
    var index: usize = 0;
    while (index < lines.items.len) {
        if (!std.mem.eql(u8, lines.items[index], begin)) {
            index += 1;
            continue;
        }

        var end_index = index;
        while (end_index < lines.items.len and !std.mem.eql(u8, lines.items[end_index], end)) {
            end_index += 1;
        }
        if (end_index < lines.items.len) end_index += 1;

        if (previous_prefix) |prefix| {
            var restored = std.ArrayListUnmanaged([]const u8).empty;
            for (lines.items[index..end_index]) |line| {
                if (std.mem.startsWith(u8, line, prefix)) {
                    restored.append(alloc, line[prefix.len..]) catch {};
                }
            }
            lines.replaceRange(alloc, index, end_index - index, restored.items) catch {};
            restored.deinit(alloc);
        } else {
            lines.replaceRange(alloc, index, end_index - index, &.{}) catch {};
        }
    }
}

fn hooksFeatureEnabled(lines: []const []const u8) bool {
    if (findDottedFeaturesHooksIndex(lines)) |index| {
        return lineDefinesTrueValue(lines[index]);
    }

    if (findFeaturesTable(lines)) |features| {
        if (findKeyInRange(lines, "hooks", features.start + 1, features.end)) |index| {
            return lineDefinesTrueValue(lines[index]);
        }
    }

    return false;
}

const TableRange = struct { start: usize, end: usize };

fn findFeaturesTable(lines: []const []const u8) ?TableRange {
    for (lines, 0..) |line, index| {
        if (!lineIsTable(line, "features")) continue;
        var end = index + 1;
        while (end < lines.len and !lineIsAnyTable(lines[end])) end += 1;
        return .{ .start = index, .end = end };
    }
    return null;
}

fn findDottedFeaturesHooksIndex(lines: []const []const u8) ?usize {
    for (lines, 0..) |line, index| {
        if (lineDefinesDottedKey(line, "features.hooks")) return index;
    }
    return null;
}

fn findKeyInRange(lines: []const []const u8, key: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (lineDefinesKey(lines[index], key)) return index;
    }
    return null;
}

fn lineIsTable(line: []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    return trimmed.len == name.len + 2 and
        trimmed[0] == '[' and
        trimmed[trimmed.len - 1] == ']' and
        std.mem.eql(u8, std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace), name);
}

fn lineIsAnyTable(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    return trimmed.len >= 2 and trimmed[0] == '[';
}

fn lineDefinesKey(line: []const u8, key: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    var index = key.len;
    while (index < trimmed.len and (trimmed[index] == ' ' or trimmed[index] == '\t')) index += 1;
    return index < trimmed.len and trimmed[index] == '=';
}

fn lineDefinesDottedKey(line: []const u8, key: []const u8) bool {
    return lineDefinesKey(line, key);
}

fn lineDefinesTrueValue(line: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const value = std.mem.trim(u8, line[equals + 1 ..], &std.ascii.whitespace);
    return std.mem.startsWith(u8, value, "true") and
        (value.len == 4 or value[4] == '#' or value[4] == ' ' or value[4] == '\t');
}

fn removeEmptyFeaturesTable(alloc: Allocator, lines: *std.ArrayListUnmanaged([]const u8)) void {
    const features = findFeaturesTable(lines.items) orelse return;
    var has_content = false;
    for (lines.items[features.start + 1 .. features.end]) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len > 0 and trimmed[0] != '#') {
            has_content = true;
            break;
        }
    }
    if (!has_content) {
        lines.replaceRange(alloc, features.start, features.end - features.start, &.{}) catch {};
    }
}

fn tomlBasicString(alloc: Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    for (value) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '"' => try out.appendSlice(alloc, "\\\""),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn readFileAllocIfExists(alloc: Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try alloc.dupe(u8, ""),
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(alloc, 10 * 1024 * 1024);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn printInstallStatus(prefix: []const u8, path: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try stdout.interface.writeAll(prefix);
    try stdout.interface.writeAll(path);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn envOwned(alloc: Allocator, key: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(alloc, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

test "agent hook state normalization" {
    try std.testing.expectEqual(NormalizedState.running, normalizeState("prompt-submit", null).?);
    try std.testing.expectEqual(NormalizedState.running, normalizeState("UserPromptSubmit", null).?);
    try std.testing.expectEqual(NormalizedState.running, normalizeState("pre_tool_use", null).?);
    try std.testing.expectEqual(NormalizedState.needs_input, normalizeState("permission-request", null).?);
    try std.testing.expectEqual(NormalizedState.needs_input, normalizeState("PermissionRequest", null).?);
    try std.testing.expectEqual(NormalizedState.needs_input, normalizeState("stop", null).?);
    try std.testing.expectEqual(NormalizedState.idle, normalizeState("SessionEnd", null).?);
    try std.testing.expectEqual(NormalizedState.errored, normalizeState("failure", null).?);
    try std.testing.expectEqual(NormalizedState.needs_input, normalizeState("pre-tool-use", "AskUserQuestion").?);
}

test "codex hook install preserves non Ghostty hooks" {
    const alloc = std.testing.allocator;
    const existing =
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo user","timeout":10}]}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    var root = try parseHooksRoot(arena_alloc, existing);
    const hooks = try ensureObjectField(arena_alloc, &root.object, "hooks");
    try removeOwnedHooksFromEvent(arena_alloc, hooks, "UserPromptSubmit");
    try appendCodexHookGroup(arena_alloc, hooks, codex_events[1]);

    const rendered = try renderJson(alloc, root, .{ .whitespace = .minified });
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "echo user") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ghostty-agent-hook") != null);
}

test "codex config install and uninstall markers" {
    const alloc = std.testing.allocator;
    const entries = [_]TrustEntry{.{
        .key = "/tmp/hooks.json:user_prompt_submit:0:0",
        .trusted_hash = "sha256:abc",
    }};

    const installed = try codexConfigTomlInstalling(alloc, "[features]\nmodel = \"x\"\n", entries[0..]);
    defer alloc.free(installed);
    try std.testing.expect(std.mem.indexOf(u8, installed, "hooks = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, installed, "[hooks.state.") != null);
    try std.testing.expect(std.mem.indexOf(u8, installed, "model = \"x\"") != null);

    const uninstalled = try codexConfigTomlUninstalling(alloc, installed);
    defer alloc.free(uninstalled);
    try std.testing.expect(std.mem.indexOf(u8, uninstalled, "ghostty-agent-codex") == null);
    try std.testing.expect(std.mem.indexOf(u8, uninstalled, "model = \"x\"") != null);
}
