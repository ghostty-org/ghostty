const build_config = @import("build_config.zig");

// See build_config.ExeEntrypoint for why we do this.
pub usingnamespace switch (build_config.exe_entrypoint) {
    .ghostty => @import("main_ghostty.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_ghostty_1 => @import("build/mdgen/main_ghostty_1.zig"),
    .mdgen_ghostty_5 => @import("build/mdgen/main_ghostty_5.zig"),
    .bench_parser => @import("bench/parser.zig"),
    .bench_stream => @import("bench/stream.zig"),
    .bench_codepoint_width => @import("bench/codepoint-width.zig"),
    .bench_grapheme_break => @import("bench/grapheme-break.zig"),
    .bench_page_init => @import("bench/page-init.zig"),
    .bench_resize => @import("bench/resize.zig"),
    .bench_screen_copy => @import("bench/screen-copy.zig"),
    .bench_vt_insert_lines => @import("bench/vt-insert-lines.zig"),
};
