const std = @import("std");
const fs = std.fs;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});
var gpa = GPA{};
const alloc = gpa.allocator();

/// Reads a .shader file and add the content of an other file at #includes customFragfilter
pub fn preprocessShaderFile(path: []const u8, customFilterPath: ?[]const u8) ![:0]const u8 {
    //defer _ = gpa.deinit();

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var preprocessedShader = std.ArrayList(u8).init(alloc);
    defer preprocessedShader.deinit();

    var buf: [256]u8 = undefined; // buffer is the maximum lenght of a single line
    while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const isInclude = std.mem.indexOf(u8, line, "#include customFragfilter") != null;
        if (isInclude) {
            if (customFilterPath) |customPath| {
                const home_config_path = try internal_os.xdg.config(alloc, .{ .subdir = "ghostty/" });
                defer alloc.free(home_config_path);

                var bufPath = [_]u8{undefined} ** std.fs.MAX_PATH_BYTES;
                const completePath = try std.fmt.bufPrint(&bufPath, "{s}{s}", .{ home_config_path, customPath });

                std.log.info("shaderFile:{s}", .{completePath});
                var includeFile = try std.fs.cwd().openFile(completePath, .{}); // Todo: Might not be the right root folder
                defer includeFile.close();

                var bufReaderInclude = std.io.bufferedReader(includeFile.reader());
                var includeReader = bufReaderInclude.reader();
                var bufInclude: [256]u8 = undefined;
                while (try includeReader.readUntilDelimiterOrEof(&bufInclude, '\n')) |lineInclude| {
                    try preprocessedShader.appendSlice(lineInclude);
                    try preprocessedShader.append('\n');
                }
            }
        } else {
            try preprocessedShader.appendSlice(line);
            try preprocessedShader.append('\n');
        }
    }
    try preprocessedShader.append('\x00');
    return @ptrCast(try preprocessedShader.toOwnedSlice());
}
