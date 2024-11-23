// This is the main file for the WASM module. The WASM module has to
// export a C ABI compatible API.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    _ = @import("os/wasm.zig");
    _ = @import("font/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("config.zig").Wasm;
    _ = @import("App.zig").Wasm;
}

const renderer = @import("renderer.zig");
const Surface = @import("Surface.zig");
const App = @import("App.zig");
const apprt = @import("apprt.zig");

const wasm = @import("os/wasm.zig");
const alloc = wasm.alloc;
const cli = @import("cli.zig");
const Config = @import("config/Config.zig");

export fn run(str: [*]const u8, len: usize) void {
    run_(str[0..len]) catch |err| {
        std.log.err("err: {?}", .{err});
    };
}
fn run_(str: []const u8) !void {
    var config = try Config.default(alloc);
    var fbs = std.io.fixedBufferStream(str);
    var iter = cli.args.lineIterator(fbs.reader());
    try config.loadIter(alloc, &iter);
    try config.finalize();
    std.log.err("font-size {}", .{config.@"font-size"});
    const app = try App.create(alloc);
    // Create our runtime app
    var app_runtime = try apprt.App.init(app, .{});
    const surface = try alloc.create(Surface);
    const apprt_surface = try alloc.create(apprt.Surface);
    try surface.init(alloc, &config, app, &app_runtime, apprt_surface);
    std.log.err("{}", .{surface.size});
    try surface.renderer.setScreenSize(surface.size);
    const esc = "\x1b[";
    surface.io.processOutput("M_yhelloaaaaaaaaa\n\r🐏\n\r👍🏽\n\rM_ghostty" ++ esc ++ "2;2H" ++ esc ++ "48;2;240;40;40m" ++ esc ++ "38;2;23;255;80mhello");
    // try surface.renderer_state.terminal.printString("M_yhelloaaaaaaaaa\n🐏\n👍🏽\nM_ghostty");
    // surface.renderer_state.terminal.setCursorPos(4, 2);
    // try surface.renderer_state.terminal.setAttribute(.{ .direct_color_bg = .{
    //     .r = 240,
    //     .g = 40,
    //     .b = 40,
    // } });
    // try surface.renderer_state.terminal.setAttribute(.{ .direct_color_fg = .{
    //     .r = 255,
    //     .g = 255,
    //     .b = 255,
    // } });
    // try surface.renderer_state.terminal.printString("hello");
    try surface.renderer.updateFrame(apprt_surface, &surface.renderer_state, false);
    try surface.renderer.drawFrame(apprt_surface);
    try surface.renderer.updateFrame(apprt_surface, &surface.renderer_state, false);
    try surface.renderer.drawFrame(apprt_surface);

    // const webgl = try renderer.OpenGL.init(alloc, .{ .config = try renderer.OpenGL.DerivedConfig.init(alloc, &config) });
    // _ = webgl;
}

pub const std_options: std.Options = .{
    // Set our log level. We try to get as much logging as possible but in
    // ReleaseSmall mode where we're optimizing for space, we elevate the
    // log level.
    // .log_level = switch (builtin.mode) {
    //     .Debug => .debug,
    //     .ReleaseSmall => .warn,
    //     else => .info,
    // },
    .log_level = .info,

    // Set our log function
    .logFn = @import("os/wasm/log.zig").log,
};
