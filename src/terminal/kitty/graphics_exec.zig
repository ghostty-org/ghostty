const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const renderer = @import("../../renderer.zig");
const point = @import("../point.zig");
const Terminal = @import("../Terminal.zig");
const command = @import("graphics_command.zig");
const image = @import("graphics_image.zig");
const Command = command.Command;
const Response = command.Response;
const LoadingImage = image.LoadingImage;
const Image = image.Image;
const ImageStorage = @import("graphics_storage.zig").ImageStorage;

const log = std.log.scoped(.kitty_gfx);

/// Execute a Kitty graphics command against the given terminal. This
/// will never fail, but the response may indicate an error and the
/// terminal state may not be updated to reflect the command. This will
/// never put the terminal in an unrecoverable state, however.
///
/// The allocator must be the same allocator that was used to build
/// the command.
pub fn execute(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) ?Response {
    // If storage is disabled then we disable the full protocol. This means
    // we don't even respond to queries so the terminal completely acts as
    // if this feature is not supported.
    if (!terminal.screen.kitty_images.enabled()) {
        log.debug("kitty graphics requested but disabled", .{});
        return null;
    }

    log.debug("executing kitty graphics command: quiet={} control={}", .{
        cmd.quiet,
        cmd.control,
    });

    const resp_: ?Response = switch (cmd.control) {
        .query => query(alloc, cmd),
        .transmit, .transmit_and_display => transmit(alloc, terminal, cmd),
        .display => display(alloc, terminal, cmd),
        .delete => delete(alloc, terminal, cmd),

        .transmit_animation_frame,
        .control_animation,
        .compose_animation,
        => .{ .message = "ERROR: unimplemented action" },
    };

    // Handle the quiet settings
    if (resp_) |resp| {
        if (!resp.ok()) {
            log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        }

        return switch (cmd.quiet) {
            .no => resp,
            .ok => if (resp.ok()) null else resp,
            .failures => null,
        };
    }

    return null;
}
/// Execute a "query" command.
///
/// This command is used to attempt to load an image and respond with
/// success/error but does not persist any of the command to the terminal
/// state.
fn query(alloc: Allocator, cmd: *Command) Response {
    const t = cmd.control.query;

    // Query requires image ID. We can't actually send a response without
    // an image ID either but we return an error and this will be logged
    // downstream.
    if (t.image_id == 0) {
        return .{ .message = "EINVAL: image ID required" };
    }

    // Build a partial response to start
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    // Attempt to load the image. If we cannot, then set an appropriate error.
    var loading = LoadingImage.init(alloc, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    loading.deinit(alloc);

    return result;
}

/// Transmit image data.
///
/// This loads the image, validates it, and puts it into the terminal
/// screen storage. It does not display the image.
fn transmit(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) Response {
    const t = cmd.transmission().?;
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };
    if (t.image_id > 0 and t.image_number > 0) {
        return .{ .message = "EINVAL: image ID and number are mutually exclusive" };
    }

    const load = loadAndAddImage(alloc, terminal, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    errdefer load.image.deinit(alloc);

    // If we're also displaying, then do that now. This function does
    // both transmit and transmit and display. The display might also be
    // deferred if it is multi-chunk.
    if (load.display) |d| {
        assert(!load.more);
        var d_copy = d;
        d_copy.image_id = load.image.id;
        return display(alloc, terminal, &.{
            .control = .{ .display = d_copy },
            .quiet = cmd.quiet,
        });
    }

    // If there are more chunks expected we do not respond.
    if (load.more) return .{};

    // After the image is added, set the ID in case it changed
    result.id = load.image.id;

    // If the original request had an image number, then we respond.
    // Otherwise, we don't respond.
    if (load.image.number == 0) return .{};

    return result;
}

/// Display a previously transmitted image.
fn display(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const d = cmd.display().?;

    // Display requires image ID or number.
    if (d.image_id == 0 and d.image_number == 0) {
        return .{ .message = "EINVAL: image ID or number required" };
    }

    // Build up our response
    var result: Response = .{
        .id = d.image_id,
        .image_number = d.image_number,
        .placement_id = d.placement_id,
    };

    // Verify the requested image exists if we have an ID
    const storage = &terminal.screen.kitty_images;
    const img_: ?Image = if (d.image_id != 0)
        storage.imageById(d.image_id)
    else
        storage.imageByNumber(d.image_number);
    const img = img_ orelse {
        result.message = "EINVAL: image not found";
        return result;
    };

    // Make sure our response has the image id in case we looked up by number
    result.id = img.id;

    // Track a new pin for our cursor. The cursor is always tracked but we
    // don't want this one to move with the cursor.
    const placement_pin = terminal.screen.pages.trackPin(
        terminal.screen.cursor.page_pin.*,
    ) catch |err| {
        log.warn("failed to create pin for Kitty graphics err={}", .{err});
        result.message = "EINVAL: failed to prepare terminal state";
        return result;
    };

    // Add the placement
    const p: ImageStorage.Placement = .{
        .pin = placement_pin,
        .x_offset = d.x_offset,
        .y_offset = d.y_offset,
        .source_x = d.x,
        .source_y = d.y,
        .source_width = d.width,
        .source_height = d.height,
        .columns = d.columns,
        .rows = d.rows,
        .z = d.z,
    };
    storage.addPlacement(
        alloc,
        img.id,
        result.placement_id,
        p,
    ) catch |err| {
        p.deinit(&terminal.screen);
        encodeError(&result, err);
        return result;
    };

    // Cursor needs to move after placement
    switch (d.cursor_movement) {
        .none => {},
        .after => {
            // We use terminal.index to properly handle scroll regions.
            const size = p.gridSize(img, terminal);
            for (0..size.rows) |_| terminal.index() catch |err| {
                log.warn("failed to move cursor: {}", .{err});
                break;
            };

            terminal.setCursorPos(
                terminal.screen.cursor.y,
                p.pin.x + size.cols + 1,
            );
        },
    }

    // Display does not result in a response on success
    return .{};
}

/// Display a previously transmitted image.
fn delete(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) Response {
    const storage = &terminal.screen.kitty_images;
    storage.delete(alloc, terminal, cmd.control.delete);

    // Delete never responds on success
    return .{};
}

fn loadAndAddImage(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) !struct {
    image: Image,
    more: bool = false,
    display: ?command.Display = null,
} {
    const t = cmd.transmission().?;
    const storage = &terminal.screen.kitty_images;

    // Determine our image. This also handles chunking and early exit.
    var loading: LoadingImage = if (storage.loading) |loading| loading: {
        // Note: we do NOT want to call "cmd.toOwnedData" here because
        // we're _copying_ the data. We want the command data to be freed.
        try loading.addData(alloc, cmd.data);

        // If we have more then we're done
        if (t.more_chunks) return .{ .image = loading.image, .more = true };

        // We have no more chunks. We're going to be completing the
        // image so we want to destroy the pointer to the loading
        // image and copy it out.
        defer {
            alloc.destroy(loading);
            storage.loading = null;
        }

        break :loading loading.*;
    } else try LoadingImage.init(alloc, cmd);

    // We only want to deinit on error. If we're chunking, then we don't
    // want to deinit at all. If we're not chunking, then we'll deinit
    // after we've copied the image out.
    errdefer loading.deinit(alloc);

    // If the image has no ID, we assign one
    if (loading.image.id == 0) {
        loading.image.id = storage.next_image_id;
        storage.next_image_id +%= 1;
    }

    // If this is chunked, this is the beginning of a new chunked transmission.
    // (We checked for an in-progress chunk above.)
    if (t.more_chunks) {
        // We allocate the pointer on the heap because its rare and we
        // don't want to always pay the memory cost to keep it around.
        const loading_ptr = try alloc.create(LoadingImage);
        errdefer alloc.destroy(loading_ptr);
        loading_ptr.* = loading;
        storage.loading = loading_ptr;
        return .{ .image = loading.image, .more = true };
    }

    // Dump the image data before it is decompressed
    // loading.debugDump() catch unreachable;

    // Validate and store our image
    var img = try loading.complete(alloc);
    errdefer img.deinit(alloc);
    try storage.addImage(alloc, img);

    // Get our display settings
    const display_ = loading.display;

    // Ensure we deinit the loading state because we're done. The image
    // won't be deinit because of "complete" above.
    loading.deinit(alloc);

    return .{ .image = img, .display = display_ };
}

const EncodeableError = Image.Error || Allocator.Error;

/// Encode an error code into a message for a response.
fn encodeError(r: *Response, err: EncodeableError) void {
    switch (err) {
        error.OutOfMemory => r.message = "ENOMEM: out of memory",
        error.InternalError => r.message = "EINVAL: internal error",
        error.InvalidData => r.message = "EINVAL: invalid data",
        error.DecompressionFailed => r.message = "EINVAL: decompression failed",
        error.FilePathTooLong => r.message = "EINVAL: file path too long",
        error.TemporaryFileNotInTempDir => r.message = "EINVAL: temporary file not in temp dir",
        error.UnsupportedFormat => r.message = "EINVAL: unsupported format",
        error.UnsupportedMedium => r.message = "EINVAL: unsupported medium",
        error.UnsupportedDepth => r.message = "EINVAL: unsupported pixel depth",
        error.DimensionsRequired => r.message = "EINVAL: dimensions required",
        error.DimensionsTooLarge => r.message = "EINVAL: dimensions too large",
    }
}
