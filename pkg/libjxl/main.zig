const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.libjxl);

pub const c = @cImport({
    @cInclude("jxl/decode.h");
    @cInclude("jxl/thread_parallel_runner.h");
});

pub const Error = error{
    JxlError,
    OutOfMemory,
    Overflow,
};

pub const ImageData = struct {
    width: u32,
    height: u32,
    data: []u8,
};

/// Maximum image size, based on the 4G limit of Ghostty's
/// `image-storage-limit` config.
pub const maximum_image_size = 4 * 1024 * 1024 * 1024;

/// Decode a JPEG XL image.
pub fn decode(alloc: Allocator, data: []const u8) Error!ImageData {
    // Create the decoder
    const decoder = c.JxlDecoderCreate(null) orelse {
        log.warn("failed to create JXL decoder", .{});
        return error.JxlError;
    };
    defer c.JxlDecoderDestroy(decoder);

    // Create the parallel runner for multi-threaded decoding
    const runner = c.JxlThreadParallelRunnerCreate(
        null,
        c.JxlThreadParallelRunnerDefaultNumWorkerThreads(),
    ) orelse {
        log.warn("failed to create JXL parallel runner", .{});
        return error.JxlError;
    };
    defer c.JxlThreadParallelRunnerDestroy(runner);

    // Set the parallel runner
    if (c.JxlDecoderSetParallelRunner(decoder, c.JxlThreadParallelRunner, runner) != c.JXL_DEC_SUCCESS) {
        log.warn("failed to set JXL parallel runner", .{});
        return error.JxlError;
    }

    // Subscribe to basic info and full image events
    if (c.JxlDecoderSubscribeEvents(decoder, c.JXL_DEC_BASIC_INFO | c.JXL_DEC_FULL_IMAGE) != c.JXL_DEC_SUCCESS) {
        log.warn("failed to subscribe to JXL events", .{});
        return error.JxlError;
    }

    // Set the input buffer
    if (c.JxlDecoderSetInput(decoder, data.ptr, data.len) != c.JXL_DEC_SUCCESS) {
        log.warn("failed to set JXL input", .{});
        return error.JxlError;
    }
    c.JxlDecoderCloseInput(decoder);

    var info: c.JxlBasicInfo = undefined;
    var width: u32 = 0;
    var height: u32 = 0;
    var destination: ?[]u8 = null;
    errdefer if (destination) |d| alloc.free(d);

    // Process the input
    while (true) {
        const status = c.JxlDecoderProcessInput(decoder);

        switch (status) {
            c.JXL_DEC_ERROR => {
                log.warn("JXL decoder error", .{});
                return error.JxlError;
            },
            c.JXL_DEC_NEED_MORE_INPUT => {
                log.warn("JXL decoder needs more input (incomplete data)", .{});
                return error.JxlError;
            },
            c.JXL_DEC_BASIC_INFO => {
                if (c.JxlDecoderGetBasicInfo(decoder, &info) != c.JXL_DEC_SUCCESS) {
                    log.warn("failed to get JXL basic info", .{});
                    return error.JxlError;
                }
                width = info.xsize;
                height = info.ysize;

                // Calculate the size and check limits
                const size: usize = @as(usize, width) * @as(usize, height) * 4; // RGBA
                if (size > maximum_image_size) {
                    log.warn("JXL image size {d} is larger than the maximum allowed ({d})", .{ size, maximum_image_size });
                    return error.Overflow;
                }

                // Allocate the destination buffer
                destination = try alloc.alloc(u8, size);

                // Set up the output buffer with RGBA format
                const format = c.JxlPixelFormat{
                    .num_channels = 4,
                    .data_type = c.JXL_TYPE_UINT8,
                    .endianness = c.JXL_NATIVE_ENDIAN,
                    .@"align" = 0,
                };

                if (c.JxlDecoderSetImageOutBuffer(
                    decoder,
                    &format,
                    destination.?.ptr,
                    destination.?.len,
                ) != c.JXL_DEC_SUCCESS) {
                    log.warn("failed to set JXL output buffer", .{});
                    return error.JxlError;
                }
            },
            c.JXL_DEC_FULL_IMAGE => {
                // Image fully decoded, we're done
            },
            c.JXL_DEC_SUCCESS => {
                // All done
                break;
            },
            else => {
                log.warn("unexpected JXL decoder status: {}", .{status});
                return error.JxlError;
            },
        }
    }

    if (destination) |d| {
        return .{
            .width = width,
            .height = height,
            .data = d,
        };
    } else {
        log.warn("JXL decoding completed but no image data", .{});
        return error.JxlError;
    }
}

test "jxl module compiles" {
    // Basic compilation test
    _ = c.JxlDecoderVersion();
}
