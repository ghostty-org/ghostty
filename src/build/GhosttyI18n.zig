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
        // We avoid using addFileArg here since the full, absolute file path
        // would be added to the file as its location, which differs for
        // everyone's checkout of the repository.
        // This comes at a cost of losing per-file caching, of course.
        xgettext.addArg(std.fmt.comptimePrint(
            "src/apprt/gtk/ui/{[major]}.{[minor]}/{[name]s}.blp",
            blp,
        ));
    }

    {
        var gtk_files = try b.build_root.handle.openDir(
            "src/apprt/gtk",
            .{ .iterate = true },
        );
        defer gtk_files.close();

        var walk = try gtk_files.walk(b.allocator);
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

            xgettext.addArg((b.pathJoin(&.{ "src/apprt/gtk", src.path })));
        }
    }

    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(
        xgettext.captureStdOut(),
        "po/" ++ domain ++ ".pot",
    );

    inline for (internal_os.i18n.locales) |locale| {
        const msgmerge = b.addSystemCommand(&.{ "msgmerge", "-q" });
        msgmerge.addFileArg(b.path("po/" ++ locale ++ ".po"));
        msgmerge.addFileArg(xgettext.captureStdOut());
        usf.addCopyFileToSource(msgmerge.captureStdOut(), "po/" ++ locale ++ ".po");
    }

    return &usf.step;
}
