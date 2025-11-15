const std = @import("std");
const builtin = @import("builtin");
const file_type = @import("file_type.zig");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.image_upload);

pub const UploadResult = union(enum) {
    success: [:0]const u8,
    failure: [:0]const u8,
    fallback,

    pub fn deinit(self: UploadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => |url| allocator.free(url),
            .failure => |err| allocator.free(err),
            .fallback => {},
        }
    }
};

pub const Uploader = struct {
    allocator: std.mem.Allocator,
    config: *const Config,

    pub fn upload(
        self: *Uploader,
        file_path: []const u8,
    ) UploadResult {
        if (!self.config.@"image-upload-enable") return .fallback;
        if (self.config.@"image-upload-url" == null) return .fallback;

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            log.err("failed to open file: {}", .{err});
            return .fallback;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            log.err("failed to stat file: {}", .{err});
            return .fallback;
        };

        const max_size = @as(u64, self.config.@"image-upload-max-size") * 1024 * 1024;
        if (stat.size > max_size) {
            log.warn("file size {} exceeds max size {}, falling back", .{ stat.size, max_size });
            return .fallback;
        }

        var header: [16]u8 = undefined;
        const bytes_read = file.read(&header) catch |err| {
            log.err("failed to read file header: {}", .{err});
            return .fallback;
        };

        var ft = file_type.FileType.detect(header[0..bytes_read]);
        if (ft == .unknown) {
            const ext = std.fs.path.extension(file_path);
            ft = file_type.FileType.guessFromExtension(ext);
            if (ft == .unknown) {
                return .fallback;
            }
        }

        file.seekTo(0) catch |err| {
            log.err("failed to seek file: {}", .{err});
            return .fallback;
        };

        const contents = file.readToEndAlloc(self.allocator, stat.size) catch |err| {
            log.err("failed to read file contents: {}", .{err});
            return .fallback;
        };
        defer self.allocator.free(contents);

        const url = self.config.@"image-upload-url".?;

        const response = self.uploadMultipart(url, contents) catch |err| {
            const err_msg = std.fmt.allocPrintZ(
                self.allocator,
                "upload failed: {s}",
                .{@errorName(err)},
            ) catch return .fallback;
            log.err("upload failed: {}", .{err});
            return .{ .failure = err_msg };
        };
        defer self.allocator.free(response);

        const uploaded_url = self.parseResponse(response) catch |err| {
            const err_msg = std.fmt.allocPrintZ(
                self.allocator,
                "failed to parse response: {s}",
                .{@errorName(err)},
            ) catch return .fallback;
            log.err("failed to parse response: {}", .{err});
            return .{ .failure = err_msg };
        };

        return .{ .success = uploaded_url };
    }

    fn uploadMultipart(
        self: *Uploader,
        url: [:0]const u8,
        contents: []const u8,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const boundary = "----GhosttyImageUploadBoundary";
        const field_name = self.config.@"image-upload-field";

        var body_list = std.ArrayList(u8).init(self.allocator);
        defer body_list.deinit();
        const body_writer = body_list.writer();

        try body_writer.print("--{s}\r\n", .{boundary});
        try body_writer.print("Content-Disposition: form-data; name=\"{s}\"; filename=\"image.png\"\r\n", .{field_name});
        try body_writer.writeAll("Content-Type: application/octet-stream\r\n\r\n");
        try body_writer.writeAll(contents);
        try body_writer.print("\r\n--{s}--\r\n", .{boundary});

        const body = try body_list.toOwnedSlice();
        defer self.allocator.free(body);

        var header_buf: [8192]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &header_buf,
            .headers = .{ .content_type = .{
                .override = try std.fmt.allocPrint(
                    self.allocator,
                    "multipart/form-data; boundary={s}",
                    .{boundary},
                ),
            } },
        });
        defer req.deinit();

        if (self.config.@"image-upload-header".list.items.len > 0) {
            for (self.config.@"image-upload-header".list.items) |header_z| {
                const header = std.mem.span(header_z);
                if (std.mem.indexOf(u8, header, ":")) |colon_pos| {
                    const name = std.mem.trim(u8, header[0..colon_pos], " \t");
                    const value = std.mem.trim(u8, header[colon_pos + 1 ..], " \t");
                    if (name.len == 0 or value.len == 0) continue;
                    try req.headers.append(name, value);
                }
            }
        }

        req.transfer_encoding = .{ .content_length = body.len };

        try req.send();
        try req.writeAll(body);
        try req.finish();

        try req.wait();

        if (req.response.status != .ok) {
            log.err("HTTP request failed with status: {}", .{req.response.status});
            return error.HttpRequestFailed;
        }

        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return response_body;
    }

    fn parseResponse(self: *Uploader, response: []const u8) ![:0]const u8 {
        const path = self.config.@"image-upload-response-path";

        if (std.mem.startsWith(u8, path, "json:")) {
            const json_path = path[5..];
            return try self.parseJsonPath(response, json_path);
        } else if (std.mem.startsWith(u8, path, "regex:")) {
            return error.RegexNotImplemented;
        } else {
            return error.InvalidResponsePath;
        }
    }

    fn parseJsonPath(self: *Uploader, response: []const u8, path: []const u8) ![:0]const u8 {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response,
            .{},
        );
        defer parsed.deinit();

        var current = parsed.value;
        var path_iter = std.mem.tokenizeScalar(u8, path, '.');

        while (path_iter.next()) |segment| {
            if (std.mem.startsWith(u8, segment, "$")) continue;

            switch (current) {
                .object => |obj| {
                    if (obj.get(segment)) |value| {
                        current = value;
                    } else {
                        log.err("JSON path segment not found: {s}", .{segment});
                        return error.JsonPathNotFound;
                    }
                },
                .array => |arr| {
                    const index = std.fmt.parseInt(usize, segment, 10) catch {
                        log.err("Invalid array index: {s}", .{segment});
                        return error.InvalidArrayIndex;
                    };
                    if (index < arr.items.len) {
                        current = arr.items[index];
                    } else {
                        log.err("Array index out of bounds: {}", .{index});
                        return error.ArrayIndexOutOfBounds;
                    }
                },
                else => {
                    log.err("Cannot traverse into non-object/array value", .{});
                    return error.InvalidJsonPath;
                },
            }
        }

        switch (current) {
            .string => |s| {
                return try self.allocator.dupeZ(u8, s);
            },
            else => {
                log.err("Final value is not a string", .{});
                return error.NotAString;
            },
        }
    }
};
