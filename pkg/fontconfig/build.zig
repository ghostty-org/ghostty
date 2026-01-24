const std = @import("std");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxml2_enabled = b.option(bool, "enable-libxml2", "Build libxml2") orelse true;
    const libxml2_iconv_enabled = b.option(
        bool,
        "enable-libxml2-iconv",
        "Build libxml2 with iconv",
    ) orelse (target.result.os.tag != .windows);
    const freetype_enabled = b.option(bool, "enable-freetype", "Build freetype") orelse true;

    const module = b.addModule("fontconfig", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    const test_exe = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    if (b.systemIntegrationOption("fontconfig", .{})) {
        module.linkSystemLibrary("fontconfig", dynamic_link_opts);
        test_exe.linkSystemLibrary2("fontconfig", dynamic_link_opts);
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,

            .libxml2_enabled = libxml2_enabled,
            .libxml2_iconv_enabled = libxml2_iconv_enabled,
            .freetype_enabled = freetype_enabled,

            .dynamic_link_opts = dynamic_link_opts,
        });

        test_exe.linkLibrary(lib);
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const libxml2_enabled = options.libxml2_enabled;
    const libxml2_iconv_enabled = options.libxml2_iconv_enabled;
    const freetype_enabled = options.freetype_enabled;

    const lib = b.addLibrary(.{
        .name = "fontconfig",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    if (target.result.os.tag != .windows) {
        lib.linkSystemLibrary("pthread");
    }

    lib.addIncludePath(b.path("override/include"));
    module.addIncludePath(b.path("override/include"));

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DHAVE_DIRENT_H",
        "-DHAVE_FCNTL_H",
        "-DHAVE_STDLIB_H",
        "-DHAVE_STRING_H",
        "-DHAVE_UNISTD_H",
        "-DHAVE_SYS_PARAM_H",

        "-DHAVE_MKSTEMP",
        //"-DHAVE_GETPROGNAME",
        //"-DHAVE_GETEXECNAME",
        "-DHAVE_RAND",
        //"-DHAVE_RANDOM_R",
        "-DHAVE_VPRINTF",

        "-DHAVE_FT_GET_BDF_PROPERTY",
        "-DHAVE_FT_GET_PS_FONT_INFO",
        "-DHAVE_FT_HAS_PS_GLYPH_NAMES",
        "-DHAVE_FT_GET_X11_FONT_FORMAT",
        "-DHAVE_FT_DONE_MM_VAR",

        "-DHAVE_POSIX_FADVISE",

        //"-DHAVE_STRUCT_STATVFS_F_BASETYPE",
        // "-DHAVE_STRUCT_STATVFS_F_FSTYPENAME",
        // "-DHAVE_STRUCT_STATFS_F_FLAGS",
        // "-DHAVE_STRUCT_STATFS_F_FSTYPENAME",
        // "-DHAVE_STRUCT_DIRENT_D_TYPE",

        "-DFLEXIBLE_ARRAY_MEMBER",

        "-DHAVE_STDATOMIC_PRIMITIVES",

        "-DFC_GPERF_SIZE_T=size_t",

        // Default errors that fontconfig can't handle
        "-Wno-implicit-function-declaration",
        "-Wno-int-conversion",

        // https://gitlab.freedesktop.org/fontconfig/fontconfig/-/merge_requests/231
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    switch (target.result.ptrBitWidth()) {
        32 => try flags.appendSlice(b.allocator, &.{
            "-DSIZEOF_VOID_P=4",
            "-DALIGNOF_VOID_P=4",
        }),

        64 => try flags.appendSlice(b.allocator, &.{
            "-DSIZEOF_VOID_P=8",
            "-DALIGNOF_VOID_P=8",
        }),

        else => @panic("unsupported arch"),
    }
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DFC_CACHEDIR=\"LOCAL_APPDATA_FONTCONFIG_CACHE\"",
            "-DFC_TEMPLATEDIR=\"c:/share/fontconfig/conf.avail\"",
            "-DCONFIGDIR=\"c:/etc/fonts/conf.d\"",
            "-DFC_DEFAULT_FONTS=\"\\t<dir>WINDOWSFONTDIR</dir>\\n\\t<dir>WINDOWSUSERFONTDIR</dir>\\n\"",
        });
    } else {
        try flags.appendSlice(b.allocator, &.{
            "-DHAVE_FSTATFS",
            "-DHAVE_FSTATVFS",
            "-DHAVE_GETOPT",
            "-DHAVE_GETOPT_LONG",
            "-DHAVE_LINK",
            "-DHAVE_LRAND48",
            "-DHAVE_LSTAT",
            "-DHAVE_MKDTEMP",
            "-DHAVE_MKOSTEMP",
            "-DHAVE__MKTEMP_S",
            "-DHAVE_MMAP",
            "-DHAVE_PTHREAD",
            "-DHAVE_RANDOM",
            "-DHAVE_RAND_R",
            "-DHAVE_READLINK",
            "-DHAVE_SYS_MOUNT_H",
            "-DHAVE_SYS_STATVFS_H",

            "-DFC_CACHEDIR=\"/var/cache/fontconfig\"",
            "-DFC_DEFAULT_FONTS=\"<dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>\"",
        });

        if (target.result.os.tag == .freebsd) {
            try flags.appendSlice(b.allocator, &.{
                "-DFC_TEMPLATEDIR=\"/usr/local/etc/fonts/conf.avail\"",
                "-DFONTCONFIG_PATH=\"/usr/local/etc/fonts\"",
                "-DCONFIGDIR=\"/usr/local/etc/fonts/conf.d\"",
            });
        } else {
            try flags.appendSlice(b.allocator, &.{
                "-DFC_TEMPLATEDIR=\"/usr/share/fontconfig/conf.avail\"",
                "-DFONTCONFIG_PATH=\"/etc/fonts\"",
                "-DCONFIGDIR=\"/usr/local/fontconfig/conf.d\"",
            });
        }

        if (target.result.os.tag == .linux) {
            try flags.appendSlice(b.allocator, &.{
                "-DHAVE_SYS_STATFS_H",
                "-DHAVE_SYS_VFS_H",
            });
        }
    }

    const dynamic_link_opts = options.dynamic_link_opts;

    // Freetype2
    _ = b.systemIntegrationOption("freetype", .{}); // So it shows up in help
    if (freetype_enabled) {
        if (b.systemIntegrationOption("freetype", .{})) {
            lib.linkSystemLibrary2("freetype2", dynamic_link_opts);
        } else {
            if (b.lazyDependency(
                "freetype",
                .{ .target = target, .optimize = optimize },
            )) |freetype_dep| {
                lib.linkLibrary(freetype_dep.artifact("freetype"));
            }
        }
    }

    // Libxml2
    _ = b.systemIntegrationOption("libxml2", .{}); // So it shows up in help
    if (libxml2_enabled) {
        try flags.appendSlice(b.allocator, &.{
            "-DENABLE_LIBXML2",
            "-DLIBXML_STATIC",
            "-DLIBXML_PUSH_ENABLED",
        });
        if (target.result.os.tag == .windows) {
            // NOTE: this should be defined on all targets
            try flags.appendSlice(b.allocator, &.{
                "-Werror=implicit-function-declaration",
            });
        }

        if (b.systemIntegrationOption("libxml2", .{})) {
            lib.linkSystemLibrary2("libxml-2.0", dynamic_link_opts);
        } else {
            if (b.lazyDependency("libxml2", .{
                .target = target,
                .optimize = optimize,
                .iconv = libxml2_iconv_enabled,
            })) |libxml2_dep| {
                lib.linkLibrary(libxml2_dep.artifact("xml2"));
            }
        }
    }

    if (b.lazyDependency("fontconfig", .{})) |upstream| {

        // NOTE: This list must be updated from `fc-lang/meson.build` whenever
        // the fontconfig version is updated.
        const orths = [_][]const u8{
            "aa.orth",
            "ab.orth",
            "af.orth",
            "am.orth",
            "ar.orth",
            "as.orth",
            "ast.orth",
            "av.orth",
            "ay.orth",
            "az_az.orth",
            "az_ir.orth",
            "ba.orth",
            "bm.orth",
            "be.orth",
            "bg.orth",
            "bh.orth",
            "bho.orth",
            "bi.orth",
            "bin.orth",
            "bn.orth",
            "bo.orth",
            "br.orth",
            "bs.orth",
            "bua.orth",
            "ca.orth",
            "ce.orth",
            "ch.orth",
            "chm.orth",
            "chr.orth",
            "co.orth",
            "cs.orth",
            "cu.orth",
            "cv.orth",
            "cy.orth",
            "da.orth",
            "de.orth",
            "dz.orth",
            "el.orth",
            "en.orth",
            "eo.orth",
            "es.orth",
            "et.orth",
            "eu.orth",
            "fa.orth",
            "fi.orth",
            "fj.orth",
            "fo.orth",
            "fr.orth",
            "ff.orth",
            "fur.orth",
            "fy.orth",
            "ga.orth",
            "gd.orth",
            "gez.orth",
            "gl.orth",
            "gn.orth",
            "gu.orth",
            "gv.orth",
            "ha.orth",
            "haw.orth",
            "he.orth",
            "hi.orth",
            "ho.orth",
            "hr.orth",
            "hu.orth",
            "hy.orth",
            "ia.orth",
            "ig.orth",
            "id.orth",
            "ie.orth",
            "ik.orth",
            "io.orth",
            "is.orth",
            "it.orth",
            "iu.orth",
            "ja.orth",
            "ka.orth",
            "kaa.orth",
            "ki.orth",
            "kk.orth",
            "kl.orth",
            "km.orth",
            "kn.orth",
            "ko.orth",
            "kok.orth",
            "ks.orth",
            "ku_am.orth",
            "ku_ir.orth",
            "kum.orth",
            "kv.orth",
            "kw.orth",
            "ky.orth",
            "la.orth",
            "lb.orth",
            "lez.orth",
            "ln.orth",
            "lo.orth",
            "lt.orth",
            "lv.orth",
            "mg.orth",
            "mh.orth",
            "mi.orth",
            "mk.orth",
            "ml.orth",
            "mn_cn.orth",
            "mo.orth",
            "mr.orth",
            "mt.orth",
            "my.orth",
            "nb.orth",
            "nds.orth",
            "ne.orth",
            "nl.orth",
            "nn.orth",
            "no.orth",
            "nr.orth",
            "nso.orth",
            "ny.orth",
            "oc.orth",
            "om.orth",
            "or.orth",
            "os.orth",
            "pa.orth",
            "pl.orth",
            "ps_af.orth",
            "ps_pk.orth",
            "pt.orth",
            "rm.orth",
            "ro.orth",
            "ru.orth",
            "sa.orth",
            "sah.orth",
            "sco.orth",
            "se.orth",
            "sel.orth",
            "sh.orth",
            "shs.orth",
            "si.orth",
            "sk.orth",
            "sl.orth",
            "sm.orth",
            "sma.orth",
            "smj.orth",
            "smn.orth",
            "sms.orth",
            "so.orth",
            "sq.orth",
            "sr.orth",
            "ss.orth",
            "st.orth",
            "sv.orth",
            "sw.orth",
            "syr.orth",
            "ta.orth",
            "te.orth",
            "tg.orth",
            "th.orth",
            "ti_er.orth",
            "ti_et.orth",
            "tig.orth",
            "tk.orth",
            "tl.orth",
            "tn.orth",
            "to.orth",
            "tr.orth",
            "ts.orth",
            "tt.orth",
            "tw.orth",
            "tyv.orth",
            "ug.orth",
            "uk.orth",
            "ur.orth",
            "uz.orth",
            "ve.orth",
            "vi.orth",
            "vo.orth",
            "vot.orth",
            "wa.orth",
            "wen.orth",
            "wo.orth",
            "xh.orth",
            "yap.orth",
            "yi.orth",
            "yo.orth",
            "zh_cn.orth",
            "zh_hk.orth",
            "zh_mo.orth",
            "zh_sg.orth",
            "zh_tw.orth",
            "zu.orth",
            "ak.orth",
            "an.orth",
            "ber_dz.orth",
            "ber_ma.orth",
            "byn.orth",
            "crh.orth",
            "csb.orth",
            "dv.orth",
            "ee.orth",
            "fat.orth",
            "fil.orth",
            "hne.orth",
            "hsb.orth",
            "ht.orth",
            "hz.orth",
            "ii.orth",
            "jv.orth",
            "kab.orth",
            "kj.orth",
            "kr.orth",
            "ku_iq.orth",
            "ku_tr.orth",
            "kwm.orth",
            "lg.orth",
            "li.orth",
            "mai.orth",
            "mn_mn.orth",
            "ms.orth",
            "na.orth",
            "ng.orth",
            "nv.orth",
            "ota.orth",
            "pa_pk.orth",
            "pap_an.orth",
            "pap_aw.orth",
            "qu.orth",
            "quz.orth",
            "rn.orth",
            "rw.orth",
            "sc.orth",
            "sd.orth",
            "sg.orth",
            "sid.orth",
            "sn.orth",
            "su.orth",
            "ty.orth",
            "wal.orth",
            "za.orth",
            "lah.orth",
            "nqo.orth",
            "brx.orth",
            "sat.orth",
            "doi.orth",
            "mni.orth",
            "und_zsye.orth",
            "und_zmth.orth",
            "anp.orth",
            "bhb.orth",
            "hif.orth",
            "mag.orth",
            "raj.orth",
            "the.orth",
            "agr.orth",
            "ayc.orth",
            "bem.orth",
            "ckb.orth",
            "cmn.orth",
            "dsb.orth",
            "hak.orth",
            "lij.orth",
            "lzh.orth",
            "mfe.orth",
            "mhr.orth",
            "miq.orth",
            "mjw.orth",
            "mnw.orth",
            "nan.orth",
            "nhn.orth",
            "niu.orth",
            "rif.orth",
            "sgs.orth",
            "shn.orth",
            "szl.orth",
            "tcy.orth",
            "tpi.orth",
            "unm.orth",
            "wae.orth",
            "yue.orth",
            "yuw.orth",
            "got.orth",
            "cop.orth",
        };

        lib.addIncludePath(upstream.path(""));
        module.addIncludePath(upstream.path(""));
        lib.addIncludePath(upstream.path("src"));
        module.addIncludePath(upstream.path("src"));

        const fontconfig_h = b.addConfigHeader(
            .{
                .style = .{
                    .cmake = upstream.path("fontconfig/fontconfig.h.in"),
                },
                .include_path = "fontconfig/fontconfig.h",
            },
            .{
                .CACHE_VERSION = "9",
            },
        );

        lib.installHeader(fontconfig_h.getOutputFile(), "fontconfig/fontconfig.h");
        lib.addConfigHeader(fontconfig_h);
        module.addConfigHeader(fontconfig_h);

        const fcstdint_h = b.addConfigHeader(
            .{
                .style = .{
                    .cmake = upstream.path("src/fcstdint.h.in"),
                },
                .include_path = "fcstdint.h",
            },
            .{},
        );

        lib.addConfigHeader(fcstdint_h);
        module.addConfigHeader(fcstdint_h);

        const generate_fc_lang_h = b.addSystemCommand(&.{"python"});
        generate_fc_lang_h.addFileArg(upstream.path("fc-lang/fc-lang.py"));
        for (orths) |orth| {
            generate_fc_lang_h.addArg(orth);
            generate_fc_lang_h.addFileInput(upstream.path(b.pathJoin(&.{ "fc-lang", orth })));
        }
        generate_fc_lang_h.addArg("--directory");
        generate_fc_lang_h.addDirectoryArg(upstream.path("fc-lang"));
        generate_fc_lang_h.addArg("--template");
        generate_fc_lang_h.addFileArg(upstream.path("fc-lang/fclang.tmpl.h"));
        generate_fc_lang_h.addArg("--output");
        const fc_lang_h = generate_fc_lang_h.addOutputFileArg("fclang.h");

        lib.addIncludePath(fc_lang_h.dirname());
        module.addIncludePath(fc_lang_h.dirname());

        const generate_fc_case_h = b.addSystemCommand(&.{"python"});
        generate_fc_case_h.addFileArg(upstream.path("fc-case/fc-case.py"));
        generate_fc_case_h.addFileArg(upstream.path("fc-case/CaseFolding.txt"));
        generate_fc_case_h.addArg("--template");
        generate_fc_case_h.addFileArg(upstream.path("fc-case/fccase.tmpl.h"));
        generate_fc_case_h.addArg("--output");
        const fc_case_h = generate_fc_case_h.addOutputFileArg("fccase.h");

        lib.addIncludePath(fc_case_h.dirname());
        module.addIncludePath(fc_case_h.dirname());

        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs,
            .flags = flags.items,
        });

        const generate_fcstr_c = b.addSystemCommand(&.{ "sed", "s@../fc-case/fccase.h@fccase.h@g" });
        generate_fcstr_c.setStdIn(.{ .lazy_path = upstream.path("src/fcstr.c") });
        const fcstr_c = generate_fcstr_c.captureStdOut();

        const c = b.addWriteFiles();
        _ = c.addCopyFile(upstream.path("src/fcstdint.h.in"), "fcstdint.h");

        lib.addIncludePath(c.getDirectory());
        module.addIncludePath(c.getDirectory());

        lib.addCSourceFile(.{
            .language = .c,
            .file = fcstr_c,
            .flags = flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path("fontconfig"),
            "fontconfig",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}

const headers = &.{
    "fontconfig/fontconfig.h",
    "fontconfig/fcprivate.h",
    "fontconfig/fcfreetype.h",
};

const srcs: []const []const u8 = &.{
    "src/fcatomic.c",
    "src/fccache.c",
    "src/fccfg.c",
    "src/fccharset.c",
    "src/fccompat.c",
    "src/fcdbg.c",
    "src/fcdefault.c",
    "src/fcdir.c",
    "src/fcformat.c",
    "src/fcfreetype.c",
    "src/fcfs.c",
    "src/fcptrlist.c",
    "src/fchash.c",
    "src/fcinit.c",
    "src/fclang.c",
    "src/fclist.c",
    "src/fcmatch.c",
    "src/fcmatrix.c",
    "src/fcname.c",
    "src/fcobjs.c",
    "src/fcpat.c",
    "src/fcrange.c",
    "src/fcserialize.c",
    "src/fcstat.c",
    "src/fcweight.c",
    "src/fcxml.c",
    "src/ftglue.c",
};
