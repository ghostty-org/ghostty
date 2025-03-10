const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("libxml2", .{});

    const lib = b.addStaticLibrary(.{
        .name = "xml2",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    lib.addIncludePath(upstream.path("include"));
    lib.addIncludePath(b.path("override/include"));
    if (target.result.os.tag == .windows) {
        lib.addIncludePath(b.path("override/config/win32"));
        lib.linkSystemLibrary("ws2_32");
    } else {
        lib.addIncludePath(b.path("override/config/posix"));
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        // Version info, hardcoded
        comptime "-DLIBXML_VERSION=" ++ Version.number(),
        comptime "-DLIBXML_VERSION_STRING=" ++ Version.string(),
        "-DLIBXML_VERSION_EXTRA=\"\"",
        comptime "-DLIBXML_DOTTED_VERSION=" ++ Version.dottedString(),

        // These might now always be true (particularly Windows) but for
        // now we just set them all. We should do some detection later.
        "-DSEND_ARG2_CAST=",
        "-DGETHOSTBYNAME_ARG_CAST=",
        "-DGETHOSTBYNAME_ARG_CAST_CONST=",

        // Always on
        "-DLIBXML_STATIC=1",
        "-DLIBXML_AUTOMATA_ENABLED=1",
        "-DWITHOUT_TRIO=1",
    });
    if (target.result.os.tag != .windows) {
        try flags.appendSlice(&.{
            "-DHAVE_ARPA_INET_H=1",
            "-DHAVE_ARPA_NAMESER_H=1",
            "-DHAVE_DL_H=1",
            "-DHAVE_NETDB_H=1",
            "-DHAVE_NETINET_IN_H=1",
            "-DHAVE_PTHREAD_H=1",
            "-DHAVE_SHLLOAD=1",
            "-DHAVE_SYS_DIR_H=1",
            "-DHAVE_SYS_MMAN_H=1",
            "-DHAVE_SYS_NDIR_H=1",
            "-DHAVE_SYS_SELECT_H=1",
            "-DHAVE_SYS_SOCKET_H=1",
            "-DHAVE_SYS_TIMEB_H=1",
            "-DHAVE_SYS_TIME_H=1",
            "-DHAVE_SYS_TYPES_H=1",
        });
    }

    // Enable our `./configure` options. For bool-type fields we translate
    // it to the `LIBXML_{field}_ENABLED` C define where field is uppercased.
    inline for (std.meta.fields(Options)) |field| {
        const opt = b.option(bool, field.name, "Configure flag") orelse
            @as(*const bool, @ptrCast(field.default_value_ptr.?)).*;
        if (opt) {
            var nameBuf: [32]u8 = undefined;
            const name = std.ascii.upperString(&nameBuf, field.name);
            const define = try std.fmt.allocPrint(b.allocator, "-DLIBXML_{s}_ENABLED=1", .{name});
            try flags.append(define);

            if (std.mem.eql(u8, field.name, "history")) {
                try flags.appendSlice(&.{
                    "-DHAVE_LIBHISTORY=1",
                    "-DHAVE_LIBREADLINE=1",
                });
            }
            if (std.mem.eql(u8, field.name, "mem_debug")) {
                try flags.append("-DDEBUG_MEMORY_LOCATION=1");
            }
            if (std.mem.eql(u8, field.name, "regexp")) {
                try flags.append("-DLIBXML_UNICODE_ENABLED=1");
            }
            if (std.mem.eql(u8, field.name, "run_debug")) {
                try flags.append("-DLIBXML_DEBUG_RUNTIME=1");
            }
            if (std.mem.eql(u8, field.name, "thread")) {
                try flags.append("-DHAVE_LIBPTHREAD=1");
            }
        }
    }

    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = srcs,
        .flags = flags.items,
    });

    lib.installHeader(
        b.path("override/include/libxml/xmlversion.h"),
        "libxml/xmlversion.h",
    );
    lib.installHeadersDirectory(
        upstream.path("include"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);
}

/// The version information for this library. This is hardcoded for now but
/// in the future we will parse this from configure.ac.
pub const Version = struct {
    pub const major = "2";
    pub const minor = "11";
    pub const micro = "5";

    pub fn number() []const u8 {
        return comptime major ++ "0" ++ minor ++ "0" ++ micro;
    }

    pub fn string() []const u8 {
        return comptime "\"" ++ number() ++ "\"";
    }

    pub fn dottedString() []const u8 {
        return comptime "\"" ++ major ++ "." ++ minor ++ "." ++ micro ++ "\"";
    }
};

/// Compile-time options for the library. These mostly correspond to
/// options exposed by the native build system used by the library.
/// These are mapped to `b.option` calls.
const Options = struct {
    // These options are all defined in libxml2's configure.c and correspond
    // to `--with-X` options for `./configure`. Their defaults are properly set.
    c14n: bool = true,
    catalog: bool = true,
    debug: bool = true,
    ftp: bool = false,
    history: bool = true,
    html: bool = true,
    iconv: bool = true,
    icu: bool = false,
    iso8859x: bool = true,
    legacy: bool = false,
    mem_debug: bool = false,
    minimum: bool = true,
    output: bool = true,
    pattern: bool = true,
    push: bool = true,
    reader: bool = true,
    regexp: bool = true,
    run_debug: bool = false,
    sax1: bool = true,
    schemas: bool = true,
    schematron: bool = true,
    thread: bool = true,
    thread_alloc: bool = false,
    tree: bool = true,
    valid: bool = true,
    writer: bool = true,
    xinclude: bool = true,
    xpath: bool = true,
    xptr: bool = true,
    xptr_locs: bool = false,
    modules: bool = true,
    lzma: bool = false,
    zlib: bool = false,
};

const srcs = &.{
    "buf.c",
    "c14n.c",
    "catalog.c",
    "chvalid.c",
    "debugXML.c",
    "dict.c",
    "encoding.c",
    "entities.c",
    "error.c",
    "globals.c",
    "hash.c",
    "HTMLparser.c",
    "HTMLtree.c",
    "legacy.c",
    "list.c",
    "nanoftp.c",
    "nanohttp.c",
    "parser.c",
    "parserInternals.c",
    "pattern.c",
    "relaxng.c",
    "SAX.c",
    "SAX2.c",
    "schematron.c",
    "threads.c",
    "tree.c",
    "uri.c",
    "valid.c",
    "xinclude.c",
    "xlink.c",
    "xmlIO.c",
    "xmlmemory.c",
    "xmlmodule.c",
    "xmlreader.c",
    "xmlregexp.c",
    "xmlsave.c",
    "xmlschemas.c",
    "xmlschemastypes.c",
    "xmlstring.c",
    "xmlunicode.c",
    "xmlwriter.c",
    "xpath.c",
    "xpointer.c",
    "xzlib.c",
};
