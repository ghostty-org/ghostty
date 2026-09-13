//! This is a wrapper package for our use of translate-c. It provides helpers
//! for short-hand addition of the translation of C files and headers, along
//! with lower-level control of the process a la the standard external
//! translate-c package.

const std = @import("std");
const apple_sdk = @import("apple_sdk");
pub const Translator = @import("translate_c").Translator;

/// Options for translation.
pub const Options = struct {
    /// Describes the specification for a single include file.
    pub const IncludeFile = struct {
        /// Describes the type of an include file.
        pub const Type = enum {
            /// A system include, included as `<file.h>`.
            system,

            /// A user-defined include, included as `"file.h"`.
            user,
        };

        /// The path to the include. Should be either a base path or a relative
        /// path, depending on what is expected via translation based on the
        /// library directory structure.
        path: []const u8,

        /// The type of include file.
        type: Type = .system,
    };

    /// The subject of the translation.
    source: union(enum) {
        /// The subject is an on-disk path and will be passed through directly
        /// for translation.
        file: std.Build.LazyPath,

        /// The subject is a collection of include files. These files will be
        /// included (in order) as system includes (e.g., `#include <foo.h>`).
        includes: struct {
            /// The name of the generated source file in cache. If not
            /// specified, will be inferred from the operation, usually the
            /// name of the import (e.g., `c.h` if the import name was "c").
            generated_name: ?[]const u8 = null,

            /// The files to include.
            files: []const IncludeFile,
        },
    },

    /// The target to perform translation as.
    target: std.Build.ResolvedTarget,

    /// The optimization mode to perform translation as.
    optimize: std.builtin.OptimizeMode,

    /// Whether or not to link in libc. Generally you want this.
    link_libc: bool = true,

    /// The system libraries to link against. These will likely line up to
    /// whatever you are translating.
    ///
    /// These system libraries are always linked against preferred-dynamic with
    /// a fallback to static.
    link_system_libs: []const []const u8 = &.{},

    /// Any additional include paths. These will be added using `-I` to the
    /// translation process, and made available to the translated code, in the
    /// order they are specified.
    include_paths: []const std.Build.LazyPath = &.{},

    /// Any additional system include paths. These will be added using
    /// `-isystem` to the translation process, and made available to the
    /// translated code, in the order they are specified.
    system_include_paths: []const std.Build.LazyPath = &.{},

    /// If supplied, these frameworks will be linked to the underlying
    /// generated Zig module via `linkFramework` in the order they are
    /// received. It does not affect translation.
    ///
    /// You likely don't need this if you are not building for an Apple
    /// platform.
    link_frameworks: []const []const u8 = &.{},

    /// Supply an external libc file. The expected format here is exactly what
    /// you would get if you ran `zig libc` and can be used if the toolchain on
    /// a particular target has a hard time auto-detecting these paths.
    libc_file: union(enum) {
        /// Auto-detect if we are targeting Darwin in the target options, and
        /// if we are, generate a libc file to use here automatically. This
        /// ensures that translation can correctly locate a MacOS SDK versus
        /// the Zig-supplied generic Darwin headers.
        detect_darwin,

        /// Supply a direct file for use here.
        direct: ?std.Build.LazyPath,
    } = .detect_darwin,

    /// Extra arguments passed to Aro. Use this if you need to pass along extra
    /// compiler flags to the translation process to make sure the headers are
    /// pre-processed correctly before translation.
    extra_args: []const []const u8 = &.{},

    /// The name of this dependency in the caller's build.zig.zon file. If you
    /// name the dependency anything else other than `translate_c`, change this
    /// to match.
    dependency_name: []const u8 = "translate_c",
};

/// Creates a translation step and adds the result as import referred to by
/// `name` to the module defined by `module`, making all translated objects
/// available to the module behind the import name.
pub fn addImportToModule(
    b: *std.Build,
    name: []const u8,
    module: *std.Build.Module,
    options: Options,
) !void {
    var init_opts = options;
    if (init_opts.source == .includes and init_opts.source.includes.generated_name == null) {
        init_opts.source.includes.generated_name = try std.fmt.allocPrint(
            b.allocator,
            "{s}.h",
            .{name},
        );
    }
    const translated = try init(b, init_opts);
    module.addImport(name, translated.mod);
}

/// Mainly serves as a pass-through for the independent translate-c
/// `Translator.init`, but also adds additional paths before returning.
///
/// Unless you need the actual translation object for more complex build
/// chains, it's recommended to use the higher-level methods such as
/// `addImportToModule`.
pub fn init(b: *std.Build, options: Options) !Translator {
    const translated = try initTranslator(b, options);
    for (options.include_paths) |path| translated.addIncludePath(path);
    for (options.system_include_paths) |path| translated.addSystemIncludePath(path);
    for (options.link_frameworks) |framework| translated.mod.linkFramework(framework, .{});
    return translated;
}

/// Mainly serves as a pass-through for the independent translate-c
/// `Translator.init`. Unless you need the actual translation object for more
/// complex build chains, it's recommended to use the higher-level methods such
/// as `addImportToModule`.
pub fn initTranslator(b: *std.Build, options: Options) !Translator {
    const this_dep = b.dependency(options.dependency_name, .{});
    const translate_c_dep = this_dep.builder.dependency("translate_c", .{});
    return .init(translate_c_dep, .{
        .c_source_file = switch (options.source) {
            .file => |f| f,
            .includes => |includes| b.addWriteFiles().add(
                includes.generated_name orelse "c.h",
                try buildSource(b, includes.files),
            ),
        },
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = options.link_libc,
        .link_system_libs = try marshalSystemLibs(b, options.link_system_libs),
        .libc_file = switch (options.libc_file) {
            .detect_darwin => if (options.target.result.os.tag.isDarwin()) libc_file: {
                switch (try apple_sdk.pathsForTarget(this_dep.builder, options.target.result)) {
                    inline else => |paths| break :libc_file paths.libc,
                }
            } else null,
            .direct => |libc_file| libc_file,
        },
        .extra_args = options.extra_args,
    });
}

/// Marshals linked system libraries into the `Translator.LinkSystemLib`
/// format, which includes the link options for each library.
///
/// All system libraries linked this way are linked dynamic-preferred with a
/// fallback to static.
///
/// Note that this uses the builder arena and as such does not need to be freed.
fn marshalSystemLibs(b: *std.Build, libs: []const []const u8) ![]Translator.LinkSystemLib {
    var result: std.ArrayList(Translator.LinkSystemLib) = .empty;
    try result.ensureTotalCapacityPrecise(b.allocator, libs.len);
    for (libs) |name| {
        result.appendAssumeCapacity(.{
            .name = name,
            .options = .{
                .preferred_link_mode = .dynamic,
                .search_strategy = .mode_first,
            },
        });
    }

    return result.items;
}

/// Builds the source for a set of `IncludeFile`s.
///
/// Note that this uses the builder arena and as such does not need to be freed.
fn buildSource(b: *std.Build, files: []const Options.IncludeFile) ![]const u8 {
    var source_builder: std.Io.Writer.Allocating = .init(b.allocator);
    for (files) |file| try fmtInclude(&source_builder.writer, file);
    return source_builder.written();
}

fn fmtInclude(w: *std.Io.Writer, file: Options.IncludeFile) !void {
    if (file.type == .system) {
        try w.print("#include <{s}>\n", .{file.path});
    } else {
        try w.print("#include \"{s}\"\n", .{file.path});
    }
}

pub fn build(b: *std.Build) void {
    _ = b;
}
