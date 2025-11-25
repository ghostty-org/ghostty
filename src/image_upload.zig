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

        const response = switch (self.config.@"image-upload-format") {
            .multipart => self.uploadMultipart(url, file_path, contents),
            .json => self.uploadJson(url, contents),
            .binary => self.uploadBinary(url, contents),
        } catch |err| {
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
        file_path: []const u8,
        contents: []const u8,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const boundary = "----GhosttyImageUploadBoundary";
        const field_name = self.config.@"image-upload-field";

        // Extract filename from file_path
        const filename = std.fs.path.basename(file_path);

        var body_list = std.ArrayList(u8).init(self.allocator);
        defer body_list.deinit();
        const body_writer = body_list.writer();

        try body_writer.print("--{s}\r\n", .{boundary});
        try body_writer.print("Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n", .{ field_name, filename });
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

        // Calculate deadline based on timeout config
        const timeout_ns = @as(u64, self.config.@"image-upload-timeout") * std.time.ns_per_s;
        const start_time = std.time.nanoTimestamp();
        const deadline = start_time + @as(i128, timeout_ns);

        try req.send();
        try req.writeAll(body);
        try req.finish();

        try req.wait();

        // Check if we exceeded timeout
        const now = std.time.nanoTimestamp();
        if (now > deadline) {
            log.err("Upload exceeded timeout of {}s", .{self.config.@"image-upload-timeout"});
            return error.UploadTimeout;
        }

        if (req.response.status != .ok) {
            log.err("HTTP request failed with status: {}", .{req.response.status});
            return error.HttpRequestFailed;
        }

        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return response_body;
    }

    fn uploadJson(
        self: *Uploader,
        url: [:0]const u8,
        contents: []const u8,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const field_name = self.config.@"image-upload-field";

        // Base64 encode the image
        const base64_encoder = std.base64.standard;
        const encoded_len = base64_encoder.Encoder.calcSize(contents.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        defer self.allocator.free(encoded);
        _ = base64_encoder.Encoder.encode(encoded, contents);

        // Build JSON body
        var body_list = std.ArrayList(u8).init(self.allocator);
        defer body_list.deinit();
        const body_writer = body_list.writer();

        try body_writer.print("{{\"{s}\":\"{s}\"}}", .{ field_name, encoded });

        const body = try body_list.toOwnedSlice();
        defer self.allocator.free(body);

        var header_buf: [8192]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &header_buf,
            .headers = .{ .content_type = .{ .override = "application/json" } },
        });
        defer req.deinit();

        // Add custom headers
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

    fn uploadBinary(
        self: *Uploader,
        url: [:0]const u8,
        contents: []const u8,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var header_buf: [8192]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &header_buf,
            .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
        });
        defer req.deinit();

        // Add custom headers
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

        req.transfer_encoding = .{ .content_length = contents.len };

        try req.send();
        try req.writeAll(contents);
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "UploadResult.deinit success" {
    const allocator = testing.allocator;
    const url = try allocator.dupeZ(u8, "https://example.com/image.png");
    const result = UploadResult{ .success = url };
    result.deinit(allocator);
}

test "UploadResult.deinit failure" {
    const allocator = testing.allocator;
    const err_msg = try allocator.dupeZ(u8, "upload failed");
    const result = UploadResult{ .failure = err_msg };
    result.deinit(allocator);
}

test "UploadResult.deinit fallback" {
    const allocator = testing.allocator;
    const result = UploadResult.fallback;
    result.deinit(allocator);
}

test "parseJsonPath simple object" {
    const allocator = testing.allocator;

    // Create minimal config
    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const json =
        \\{
        \\  "data": {
        \\    "link": "https://i.imgur.com/abc123.png"
        \\  }
        \\}
    ;

    const url = try uploader.parseJsonPath(json, "$.data.link");
    defer allocator.free(url);

    try testing.expectEqualStrings("https://i.imgur.com/abc123.png", url);
}

test "parseJsonPath nested object" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const json =
        \\{
        \\  "response": {
        \\    "data": {
        \\      "url": "https://example.com/test.jpg"
        \\    }
        \\  }
        \\}
    ;

    const url = try uploader.parseJsonPath(json, "$.response.data.url");
    defer allocator.free(url);

    try testing.expectEqualStrings("https://example.com/test.jpg", url);
}

test "parseJsonPath array access" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const json =
        \\{
        \\  "images": [
        \\    "https://example.com/first.png",
        \\    "https://example.com/second.png"
        \\  ]
        \\}
    ;

    const url = try uploader.parseJsonPath(json, "$.images.0");
    defer allocator.free(url);

    try testing.expectEqualStrings("https://example.com/first.png", url);
}

test "parseJsonPath missing field" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const json =
        \\{
        \\  "data": {
        \\    "link": "https://example.com/test.png"
        \\  }
        \\}
    ;

    const result = uploader.parseJsonPath(json, "$.data.missing");
    try testing.expectError(error.JsonPathNotFound, result);
}

test "parseJsonPath non-string value" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const json =
        \\{
        \\  "data": {
        \\    "count": 42
        \\  }
        \\}
    ;

    const result = uploader.parseJsonPath(json, "$.data.count");
    try testing.expectError(error.NotAString, result);
}

test "parseResponse with json prefix" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;
    config.@"image-upload-response-path" = "json:$.data.link";

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const json =
        \\{
        \\  "data": {
        \\    "link": "https://i.imgur.com/test.png"
        \\  }
        \\}
    ;

    const url = try uploader.parseResponse(json);
    defer allocator.free(url);

    try testing.expectEqualStrings("https://i.imgur.com/test.png", url);
}

test "parseResponse with regex prefix returns error" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = null;
    config.@"image-upload-response-path" = "regex:https?://.*";

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const response = "https://example.com/test.png";
    const result = uploader.parseResponse(response);
    try testing.expectError(error.RegexNotImplemented, result);
}

test "upload returns fallback when disabled" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = false;
    config.@"image-upload-url" = "https://api.example.com/upload";

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const result = uploader.upload("/tmp/test.png");
    defer result.deinit(allocator);

    try testing.expect(result == .fallback);
}

test "upload returns fallback when url is null" {
    const allocator = testing.allocator;

    var config = Config{};
    config.@"image-upload-enable" = true;
    config.@"image-upload-url" = null;

    var uploader = Uploader{
        .allocator = allocator,
        .config = &config,
    };

    const result = uploader.upload("/tmp/test.png");
    defer result.deinit(allocator);

    try testing.expect(result == .fallback);
}
