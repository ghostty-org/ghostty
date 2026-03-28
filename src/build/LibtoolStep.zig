//! A zig builder step that runs "libtool" against a list of libraries
//! in order to create a single combined static library.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []LazyPath,
};

/// The step to depend on.
step: *Step,

/// The output file from the libtool run.
output: LazyPath,

/// Run libtool against a list of library files to combine into a single
/// static library.
///
/// Zig's ar implementation does not guarantee 8-byte alignment for 64-bit
/// Mach-O object files within archives. Apple's libtool silently drops
/// misaligned members. To work around this, we use a shell script that
/// re-archives each input library with the system ar (which produces
/// correctly aligned archives) before combining them with libtool.
pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("libtool {s} ({s})", .{ opts.name, opts.out_name }));
    run_step.has_side_effects = true;
    run_step.addArgs(&.{
        "/bin/sh",
        "-c",
        \\set -e
        \\OUTPUT="$1"; shift
        \\TMPDIR=$(mktemp -d)
        \\trap 'rm -rf "$TMPDIR"' EXIT
        \\ORIGDIR="$PWD"
        \\FIXED=""
        \\IDX=0
        \\for lib in "$@"; do
        \\  case "$lib" in /*) ;; *) lib="$ORIGDIR/$lib";; esac
        \\  dir="$TMPDIR/$IDX"
        \\  mkdir -p "$dir"
        \\  (cd "$dir" && ar x "$lib" && chmod 644 *.o 2>/dev/null)
        \\  fixed="$TMPDIR/fixed_$IDX.a"
        \\  /usr/bin/ar rcs "$fixed" "$dir"/*.o
        \\  FIXED="$FIXED $fixed"
        \\  IDX=$((IDX + 1))
        \\done
        \\case "$OUTPUT" in /*) ;; *) OUTPUT="$ORIGDIR/$OUTPUT";; esac
        \\libtool -static -o "$OUTPUT" $FIXED
        ,
        "libtool", // $0
    });
    const output = run_step.addOutputFileArg(opts.out_name); // $1
    for (opts.sources) |source| run_step.addFileArg(source); // $2, $3, ...

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}
