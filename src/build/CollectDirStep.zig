//! Collects a set of generated files into one directory in the build cache,
//! keyed on the *contents* of those files and nothing else.
//!
//! `std.Build.Step.WriteFile` is the obvious way to do this and is the wrong
//! one, because of how it hashes what it copies. Zig's cache manifest folds
//! the *path* of an input into the hash alongside its bytes -- see
//! `std.Build.Cache.Manifest.addFileInner`, which does:
//!
//!     self.hash.add(prefixed_path.prefix);
//!     self.hash.addBytes(prefixed_path.sub_path);
//!
//! For a file that came out of another step, that path contains that step's
//! own hash. So a producing step that is re-run for a reason of its own --
//! it was relinked, or one of *its* inputs moved -- writes byte for byte
//! identical output to a brand new directory, and every consumer sees a
//! changed input and rebuilds. Since each consumer's output directory then
//! moves too, the churn does not damp out as it travels; it reaches the far
//! end of the graph at full strength.
//!
//! That is what this step exists to stop. It hashes only the destination
//! layout and the bytes of each file, so identical bytes always land in the
//! same directory no matter where they were produced. Downstream steps hash
//! that stable path, and a rebuild that changed nothing stops here instead
//! of propagating.
//!
//! Use it where a generated tree feeds an expensive consumer and the
//! producer is prone to churning for reasons that do not change its output.
//! It reads every input on every build to hash it, so it suits many small
//! files rather than a few large ones.

const CollectDir = @This();

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Step = std.Build.Step;

/// The largest input this step will read. Generous for the text files this
/// is meant for, and a bounded failure rather than an allocation the size
/// of whatever it was handed.
const max_file_size = 64 * 1024 * 1024;

step: Step,
files: std.ArrayList(File),
generated_directory: std.Build.GeneratedFile,

pub const File = struct {
    /// Where the file goes, relative to the collected directory.
    sub_path: []const u8,
    source: std.Build.LazyPath,
};

pub fn create(b: *std.Build, name: []const u8) *CollectDir {
    const self = b.allocator.create(CollectDir) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = name,
            .owner = b,
            .makeFn = make,
        }),
        .files = .empty,
        .generated_directory = .{ .step = &self.step },
    };
    return self;
}

/// Copy `source` into the collected directory at `sub_path`.
pub fn addCopyFile(
    self: *CollectDir,
    source: std.Build.LazyPath,
    sub_path: []const u8,
) void {
    const b = self.step.owner;
    self.files.append(b.allocator, .{
        .sub_path = b.dupe(sub_path),
        .source = source.dupe(b),
    }) catch @panic("OOM");
    source.addStepDependencies(&self.step);
}

/// The collected directory.
pub fn getDirectory(self: *CollectDir) std.Build.LazyPath {
    return .{ .generated = .{ .file = &self.generated_directory } };
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;

    const b = step.owner;
    const io = b.graph.io;
    const gpa = b.graph.cache.gpa;
    const arena = b.allocator;
    const self: *CollectDir = @fieldParentPtr("step", step);

    var man = b.graph.cache.obtain();
    defer man.deinit();

    // The whole point of this step: the destination layout and the file
    // bytes go into the hash, and the source paths deliberately do not.
    // `man.addFilePath` would add them, so read the files ourselves.
    for (self.files.items) |file| {
        man.hash.addBytes(file.sub_path);

        const source_path = file.source.getPath3(b, step);
        const contents = source_path.root_dir.handle.readFileAlloc(
            io,
            source_path.subPathOrDot(),
            gpa,
            .limited(max_file_size),
        ) catch |err| return step.fail(
            "unable to read '{f}': {t}",
            .{ source_path, err },
        );
        defer gpa.free(contents);

        man.hash.addBytes(contents);
    }

    if (try step.cacheHit(&man)) {
        const digest = man.final();
        self.generated_directory.path = try b.cache_root.join(
            arena,
            &.{ "o", &digest },
        );
        return;
    }

    const digest = man.final();
    const cache_path = "o" ++ Dir.path.sep_str ++ digest;
    const root_path: std.Build.Cache.Path = .{
        .root_dir = b.cache_root,
        .sub_path = cache_path,
    };
    self.generated_directory.path = try b.cache_root.join(arena, &.{cache_path});

    var cache_dir = root_path.root_dir.handle.createDirPathOpen(
        io,
        root_path.sub_path,
        .{},
    ) catch |err| return step.fail(
        "unable to make path {f}: {t}",
        .{ root_path, err },
    );
    defer cache_dir.close(io);

    for (self.files.items) |file| {
        if (Dir.path.dirname(file.sub_path)) |dirname| {
            cache_dir.createDirPath(io, dirname) catch |err| return step.fail(
                "unable to make path '{f}{c}{s}': {t}",
                .{ root_path, Dir.path.sep, dirname, err },
            );
        }

        const source_path = file.source.getPath2(b, step);
        _ = Io.Dir.updateFile(
            .cwd(),
            io,
            source_path,
            cache_dir,
            file.sub_path,
            .{},
        ) catch |err| return step.fail(
            "unable to copy '{s}' to '{f}{c}{s}': {t}",
            .{ source_path, root_path, Dir.path.sep, file.sub_path, err },
        );
    }

    try step.writeManifest(&man);
}
