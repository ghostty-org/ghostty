const GhosttyI18n = @This();

const std = @import("std");
const Config = @import("Config.zig");
const locales = @import("../os/i18n_locales.zig").locales;

owner: *std.Build,
steps: []*std.Build.Step,

/// This step updates the translation files on disk that should be
/// committed to the repo.
update_step: *std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyI18n {
    _ = cfg;

    var steps: std.ArrayList(*std.Build.Step) = .empty;
    defer steps.deinit(b.allocator);

    inline for (locales) |locale| {
        // There is no encoding suffix in the LC_MESSAGES path on FreeBSD,
        // so we need to remove it from `locale` to have a correct destination string.
        // (/usr/local/share/locale/en_AU/LC_MESSAGES)
        const target_locale = comptime if (builtin.target.os.tag == .freebsd)
            std.mem.trimRight(u8, locale, ".UTF-8")
        else
            locale;

        const msgfmt = b.addSystemCommand(&.{ "msgfmt", "-o", "-" });
        msgfmt.addFileArg(b.path("po/" ++ locale ++ ".po"));

        try steps.append(b.allocator, &b.addInstallFile(
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
        .steps = try steps.toOwnedSlice(b.allocator),
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
    const step = b.step(
        "update-translations-disabled",
        "Translation extraction is disabled in the Windows-only fork.",
    );
    try step.addError(
        "update-translations is not supported in the Windows-only fork",
        .{},
    );
    return step;
}
