//! Apple Help Book bundle for the macOS app.
//!
//! This generates a complete `Ghostty.help` bundle: the bundle Info.plist
//! and PkgInfo, a title/index page, and one HTML page per config option and
//! bindable keybind action (options documented by a preceding option, like
//! the `font-family` style variants, share that option's page). The pages
//! are styled after the Ghostty website documentation. The build then indexes the bundle with `hiutil` and copies
//! it into the macOS app bundle, where Help Viewer picks it up via the
//! CFBundleHelpBook* keys in the app Info.plist.
//!
//! All markup lives as plain HTML/CSS/JS files in the `help_book/`
//! directory. Pages with dynamic content are `{{placeholder}}` templates
//! filled in by `help_book/template.zig`; the dynamic content itself is
//! rendered from the in-repo markdown docs and the config/keybind doc
//! comments by `help_book/markdown.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../build_config.zig");
const Config = @import("../config/Config.zig");
const CliAction = @import("../cli.zig").ghostty.Action;
const KeybindAction = @import("../input.zig").Binding.Action;
const help_strings = @import("help_strings");
const markdown = @import("help_book/markdown.zig");
const template = @import("help_book/template.zig");

/// The help book identifier. The app Info.plist's CFBundleHelpBookName
/// must match this value.
pub const book_identifier = "com.mitchellh.ghostty.help";

const book_title = "Ghostty Help";

/// Bundle files copied into en.lproj verbatim.
const static_files = [_]struct {
    name: []const u8,
    data: []const u8,
}{
    .{ .name = "style.css", .data = @embedFile("help_book/style.css") },
    .{ .name = "content.js", .data = @embedFile("help_book/content.js") },
    .{ .name = "shell.js", .data = @embedFile("help_book/shell.js") },
};

/// Where the home page version links, mirroring the About window: dev
/// builds link to the commit (the version's `+` build metadata) on
/// GitHub, stable X.Y.Z releases link to their release notes.
const version_url = url: {
    const v = build_config.version_string;
    if (std.mem.lastIndexOfScalar(u8, v, '+')) |idx| {
        const commit = v[idx + 1 ..];
        // The all-zero commit is the no-git fallback version.
        if (commit.len > 0 and !std.mem.eql(u8, commit, "0000000"))
            break :url "https://github.com/ghostty-org/ghostty/commits/" ++ commit;
        break :url "https://github.com/ghostty-org/ghostty";
    }
    const slug = slug: {
        var out: [v.len]u8 = undefined;
        for (v, 0..) |c, i| out[i] = if (c == '.') '-' else c;
        const final = out;
        break :slug final;
    };
    break :url "https://ghostty.org/docs/install/release-notes/" ++ slug;
};

const Kind = enum {
    option,
    action,

    fn docsUrl(self: Kind) []const u8 {
        return switch (self) {
            .option => "https://ghostty.org/docs/config/reference#",
            .action => "https://ghostty.org/docs/config/keybind/reference#",
        };
    }

    fn keyword(self: Kind) []const u8 {
        return switch (self) {
            .option => "config",
            .action => "keybind",
        };
    }
};

const Topic = struct {
    kind: Kind,
    /// The names sharing this topic; the first is the primary name that
    /// names the page file.
    names: []const []const u8,
    doc: []const u8,
};

/// Every config option and keybind action with its doc comment, in
/// declaration order. This is the single source for both the sidebar
/// table of contents and the per-topic pages.
///
/// A field without a doc comment of its own is documented by the field
/// preceding it (e.g. `font-family-bold` by `font-family`); such fields
/// join the preceding topic and share its page.
const topics = topics: {
    @setEvalBranchQuota(1_000_000);
    const options = topicList(
        .option,
        @typeInfo(Config).@"struct".fields,
        help_strings.Config,
    );
    const actions = topicList(
        .action,
        @typeInfo(KeybindAction).@"union".fields,
        help_strings.KeybindAction,
    );
    break :topics options ++ actions;
};

fn topicList(
    comptime kind: Kind,
    comptime fields: anytype,
    comptime Help: type,
) []const Topic {
    @setEvalBranchQuota(1_000_000);
    var list: []const Topic = &.{};
    for (fields) |field| {
        if (field.name[0] == '_') continue;
        if (!@hasDecl(Help, field.name) and list.len > 0) {
            // Undocumented: share the preceding topic and its page.
            const prev = list[list.len - 1];
            list = list[0 .. list.len - 1] ++ [_]Topic{.{
                .kind = kind,
                .names = prev.names ++ [_][]const u8{field.name},
                .doc = prev.doc,
            }};
            continue;
        }
        list = list ++ [_]Topic{.{
            .kind = kind,
            .names = &.{field.name},
            .doc = docOf(Help, field.name),
        }};
    }
    return list;
}

/// Every CLI action with its display name (--help/--version/+action) and
/// doc comment, for the CLI documentation page.
const cli_actions = cli: {
    @setEvalBranchQuota(100_000);
    const fields = @typeInfo(CliAction).@"enum".fields;
    var list: [fields.len]struct {
        name: []const u8,
        display: []const u8,
        doc: []const u8,
    } = undefined;
    for (fields, 0..) |field, i| {
        list[i] = .{
            .name = field.name,
            .display = if (std.mem.eql(u8, field.name, "help"))
                "--help"
            else if (std.mem.eql(u8, field.name, "version"))
                "--version"
            else
                "+" ++ field.name,
            .doc = docOf(help_strings.Action, field.name),
        };
    }
    const final = list;
    break :cli final;
};

fn docOf(comptime T: type, comptime name: [:0]const u8) []const u8 {
    return if (@hasDecl(T, name)) @field(T, name) else "";
}

/// CLI entrypoint for `+help-book <dir>`: write the bundle into the
/// directory given as the first non-action argument.
pub fn writeCli(alloc: Allocator, io: std.Io, args: std.process.Args) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const argv = try args.toSlice(arena_state.allocator());
    const path = for (argv[1..]) |arg| {
        if (arg.len > 0 and arg[0] != '+') break arg;
    } else return error.MissingOutputDirectory;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);
    try write(alloc, io, dir);
}

/// Write the complete help book bundle contents into the given directory,
/// which becomes the `Ghostty.help` bundle root.
pub fn write(alloc: Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try dir.createDirPath(io, "Contents/Resources/en.lproj");
    // We need this for macOS to recognize this bundle as a help book
    // and indexing it properly.
    try dir.writeFile(io, .{ .sub_path = "Contents/PkgInfo", .data = "BNDLhbwr" });
    // The book version mirrors the app version (`ghostty +version`) so
    // Help Viewer's helpd cache is invalidated on every app update. The
    // short version is the plain semver triple as Apple requires for
    // CFBundleShortVersionString.
    try writeTemplateFile(io, dir, "Contents/Info.plist", @embedFile("help_book/Info.plist"), .{
        .identifier = book_identifier,
        .title = book_title,
        .version = build_config.version_string,
        .short_version = std.fmt.comptimePrint("{d}.{d}.{d}", .{
            build_config.version.major,
            build_config.version.minor,
            build_config.version.patch,
        }),
    });

    var lproj = try dir.openDir(io, "Contents/Resources/en.lproj", .{});
    defer lproj.close(io);

    for (static_files) |file| {
        try lproj.writeFile(io, .{ .sub_path = file.name, .data = file.data });
    }

    // The landing page, showing the app version linked as in the About
    // window. The wordmark is the website's, downloaded from
    // https://ghostty.org/_next/static/media/ghostty-wordmark.815bf882.svg
    // with the lettering fill changed to currentColor.
    try writeTemplateFile(io, lproj, "home.html", @embedFile("help_book/home.html"), .{
        .version = build_config.version_string,
        .version_url = version_url,
        .wordmark = @embedFile("help_book/wordmark.svg"),
    });

    // The persistent shell: sidebar plus a content iframe. All other pages
    // load inside the iframe so the sidebar never reloads while navigating.
    {
        var options_toc: std.Io.Writer.Allocating = .init(arena);
        var actions_toc: std.Io.Writer.Allocating = .init(arena);
        for (topics) |topic| {
            const toc = switch (topic.kind) {
                .option => &options_toc,
                .action => &actions_toc,
            };
            // One entry per topic, under its primary name. The other
            // names of a group are findable through search (they are
            // keywords of the shared page) and called out on the page.
            const name = topic.names[0];
            try toc.writer.print(
                "<li><a id=\"{s}.{s}\" href=\"{s}.{s}.html\" target=\"content\">{s}</a></li>\n",
                .{ @tagName(topic.kind), name, @tagName(topic.kind), name, name },
            );
        }
        try writeTemplateFile(io, lproj, "index.html", @embedFile("help_book/index.html"), .{
            .options_toc = options_toc.written(),
            .actions_toc = actions_toc.written(),
        });
    }

    // Documentation pages rendered from the in-repo markdown docs
    // (the same sources as the ghostty(1)/ghostty(5) man pages).
    try writeTemplateFile(io, lproj, "docs.config.html", @embedFile("help_book/docs_config.html"), .{
        .header = try renderMarkdown(arena, @embedFile("../build/mdgen/ghostty_5_header.md")),
    });
    {
        var actions_html: std.Io.Writer.Allocating = .init(arena);
        for (cli_actions) |action| {
            try actions_html.writer.print(
                "<h3 id=\"cli.{s}\"><code>{s}</code></h3>\n",
                .{ action.name, action.display },
            );
            try markdown.render(arena, &actions_html.writer, action.doc);
        }
        try writeTemplateFile(io, lproj, "docs.cli.html", @embedFile("help_book/docs_cli.html"), .{
            .header = try renderMarkdown(arena, @embedFile("../build/mdgen/ghostty_1_header.md")),
            .actions = actions_html.written(),
        });
    }

    // One page per config option and keybind action.
    for (topics) |topic| {
        _ = arena_state.reset(.retain_capacity);
        try writeTopicFile(arena, io, lproj, topic);
    }
}

fn writeTopicFile(arena: Allocator, io: std.Io, lproj: std.Io.Dir, topic: Topic) !void {
    var body: std.Io.Writer.Allocating = .init(arena);
    try markdown.render(arena, &body.writer, topic.doc);

    var description: std.Io.Writer.Allocating = .init(arena);
    try writeMetaDescription(&description.writer, topic.doc);

    const kind = @tagName(topic.kind);
    const primary = topic.names[0];

    // Every name of the group is a search keyword (that is how Apple
    // Help routes alternate terms to a page); the non-primary names are
    // also called out below the title.
    var names: std.Io.Writer.Allocating = .init(arena);
    var variants: std.Io.Writer.Allocating = .init(arena);
    for (topic.names, 0..) |name, i| {
        if (i > 0) try names.writer.writeAll(", ");
        try names.writer.writeAll(name);
    }
    if (topic.names.len > 1) {
        try variants.writer.writeAll("<p class=\"variants\">Also applies to ");
        for (topic.names[1..], 0..) |name, i| {
            if (i > 0) try variants.writer.writeAll(", ");
            try variants.writer.print("<code>{s}</code>", .{name});
        }
        try variants.writer.writeAll(".</p>\n");
    }

    const file_name = try std.fmt.allocPrint(arena, "{s}.{s}.html", .{ kind, primary });
    try writeTemplateFile(io, lproj, file_name, @embedFile("help_book/topic.html"), .{
        .name = primary,
        .names = names.written(),
        .description = description.written(),
        .keyword = topic.kind.keyword(),
        .anchor = try std.fmt.allocPrint(arena, "{s}.{s}", .{ kind, primary }),
        .variants = variants.written(),
        .body = body.written(),
        .docs_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ topic.kind.docsUrl(), primary }),
    });
}

/// Create the file and write the template with placeholders substituted.
fn writeTemplateFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    comptime source: []const u8,
    args: anytype,
) !void {
    var f = try dir.createFile(io, sub_path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fw = f.writerStreaming(io, &buf);
    try template.write(&fw.interface, source, args);
    try fw.end();
}

/// Render markdown to an HTML string for use as a template value.
fn renderMarkdown(arena: Allocator, source: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try markdown.render(arena, &out.writer, source);
    return out.written();
}

/// Write the first line of the doc text, truncated to at most 160 bytes at
/// a UTF-8 boundary, as an HTML-escaped search-result abstract. Markdown
/// backticks are stripped since abstracts are plain text.
fn writeMetaDescription(w: *std.Io.Writer, doc: []const u8) !void {
    var line = doc[0 .. std.mem.indexOfScalar(u8, doc, '\n') orelse doc.len];
    if (line.len > 160) {
        var end: usize = 160;
        while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
        line = line[0..end];
    }
    for (line) |c| {
        if (c == '`') continue;
        try markdown.writeEscapedByte(w, c);
    }
}

test "help book" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(alloc, io, tmp.dir);

    // Undocumented options share the page of the option documenting them,
    // with no page of their own: searchable there through the keywords and
    // called out below the title. Topic pages link back to the online docs.
    {
        const page = try tmp.dir.readFileAlloc(io, "Contents/Resources/en.lproj/option.font-family.html", alloc, .limited(1 << 20));
        defer alloc.free(page);
        try testing.expect(std.mem.indexOf(u8, page, "content=\"ghostty, config, font-family, font-family-bold, font-family-italic, font-family-bold-italic\"") != null);
        try testing.expect(std.mem.indexOf(u8, page, "<p class=\"variants\">") != null);
        try testing.expect(std.mem.indexOf(u8, page, "https://ghostty.org/docs/config/reference#font-family") != null);
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, "Contents/Resources/en.lproj/option.font-family-bold.html", .{}));
    }
}
