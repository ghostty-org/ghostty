const GhosttyI18n = @This();

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");
const gresource = @import("../apprt/gtk/gresource.zig");
const internal_os = @import("../os/main.zig");

const domain = "com.mitchellh.ghostty";

owner: *std.Build,
steps: []*std.Build.Step,

/// This step updates the translation files on disk that should be
/// committed to the repo.
update_step: *std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyI18n {
    _ = cfg;

    var steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    defer steps.deinit();

    inline for (internal_os.i18n.locales) |locale| {
        // There is no encoding suffix in the LC_MESSAGES path on FreeBSD,
        // so we need to remove it from `locale` to have a correct destination string.
        // (/usr/local/share/locale/en_AU/LC_MESSAGES)
        const target_locale = comptime if (builtin.target.os.tag == .freebsd)
            std.mem.trimRight(u8, locale, ".UTF-8")
        else
            locale;

        const msgfmt = b.addSystemCommand(&.{ "msgfmt", "-o", "-" });
        msgfmt.addFileArg(b.path("po/" ++ locale ++ ".po"));

        try steps.append(&b.addInstallFile(
            msgfmt.captureStdOut(),
            std.fmt.comptimePrint(
                "share/locale/{s}/LC_MESSAGES/{s}.mo",
                .{ target_locale, domain },
            ),
        ).step);
    }

    return .{
        .owner = b,
        .update_step = try createUpdateStep(b),
        .steps = try steps.toOwnedSlice(),
    };
}

pub fn install(self: *const GhosttyI18n) void {
    self.addStepDependencies(self.owner.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyI18n,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}

fn createUpdateStep(b: *std.Build) !*std.Build.Step {
    const xgettext = b.addSystemCommand(&.{
        "xgettext",
        "--language=C", // Silence the "unknown extension" errors
        "--from-code=UTF-8",
        "--add-comments=Translators",
        "--keyword=_",
        "--keyword=C_:1c,2",
        "--package-name=" ++ domain,
        "--msgid-bugs-address=m@mitchellh.com",
        "--copyright-holder=\"Mitchell Hashimoto, Ghostty contributors\"",
        "-o",
        "-",
    });

    // Not cacheable due to the gresource files
    xgettext.has_side_effects = true;

    inline for (gresource.blueprint_files) |blp| {
        const path = std.fmt.comptimePrint(
            "src/apprt/gtk/ui/{[major]}.{[minor]}/{[name]s}.blp",
            blp,
        );
        // The arguments to xgettext must be the relative path in the build root
        // or the resulting files will contain the absolute path. This will cause
        // a lot of churn because not everyone has the Ghostty code checked out in
        // exactly the same location.
        xgettext.addArg(path);
        // Mark the file as an input so that the Zig build system caching will work.
        xgettext.addFileInput(b.path(path));
    }

    {
        // Iterate over all of the files underneath `src/apprt/gtk`. We store
        // them in an array so that they can be sorted into a determininistic
        // order. That will minimize code churn as directory walking is not
        // guaranteed to happen in any particular order.

        var gtk_files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (gtk_files.items) |item| b.allocator.free(item);
            gtk_files.deinit(b.allocator);
        }

        var gtk_dir = try b.build_root.handle.openDir(
            "src/apprt/gtk",
            .{ .iterate = true },
        );
        defer gtk_dir.close();

        var walk = try gtk_dir.walk(b.allocator);
        defer walk.deinit();
        while (try walk.next()) |src| {
            switch (src.kind) {
                .file => if (!std.mem.endsWith(
                    u8,
                    src.basename,
                    ".zig",
                )) continue,

                else => continue,
            }

            try gtk_files.append(b.allocator, try b.allocator.dupe(u8, src.path));
        }

        std.mem.sort(
            []const u8,
            gtk_files.items,
            {},
            struct {
                fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lt,
        );

        for (gtk_files.items) |item| {
            const path = b.pathJoin(&.{ "src/apprt/gtk", item });
            // The arguments to xgettext must be the relative path in the build root
            // or the resulting files will contain the absolute path. This will
            // cause a lot of churn because not everyone has the Ghostty code
            // checked out in exactly the same location.
            xgettext.addArg(path);
            // Mark the file as an input so that the Zig build system caching will work.
            xgettext.addFileInput(b.path(path));
        }
    }

    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(
        xgettext.captureStdOut(),
        "po/" ++ domain ++ ".pot",
    );

    inline for (internal_os.i18n.locales) |locale| {
        const msgmerge = b.addSystemCommand(&.{ "msgmerge", "--quiet", "--no-fuzzy-matching" });
        msgmerge.addFileArg(b.path("po/" ++ locale ++ ".po"));
        msgmerge.addFileArg(xgettext.captureStdOut());
        usf.addCopyFileToSource(msgmerge.captureStdOut(), "po/" ++ locale ++ ".po");
    }

    return &usf.step;
}
