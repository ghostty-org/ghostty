const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

const Terminal = @import("../Terminal.zig");
const command = @import("graphics_command.zig");
const image = @import("graphics_image.zig");
const animation = @import("graphics_animation.zig");
const pixel = @import("graphics_pixel.zig");
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
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) ?Response {
    // If storage is disabled then we disable the full protocol. This means
    // we don't even respond to queries so the terminal completely acts as
    // if this feature is not supported.
    if (!terminal.screens.active.kitty_images.enabled()) {
        log.debug("kitty graphics requested but disabled", .{});
        return null;
    }

    log.debug("executing kitty graphics command: quiet={} control={}", .{
        cmd.quiet,
        cmd.control,
    });

    // The quiet settings used to control the response. We have to make this
    // a var because in certain special cases (namely chunked transmissions)
    // this can change.
    var quiet = cmd.quiet;

    // The protocol makes i and I mutually exclusive for every action, so this
    // must happen before dispatch and before an action can mutate storage.
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#requesting-image-ids-from-the-terminal
    const identifiers = cmd.control.identifiers();
    if (identifiers.image_id > 0 and identifiers.image_number > 0) {
        const resp: Response = .{
            .id = identifiers.image_id,
            .image_number = identifiers.image_number,
            .placement_id = identifiers.placement_id,
            .message = "EINVAL: image ID and number are mutually exclusive",
        };
        log.warn("erroneous kitty graphics response: {s}", .{resp.message});

        return switch (quiet) {
            .no => resp,
            .ok => resp,
            .failures => null,
        };
    }

    const resp_: ?Response = switch (cmd.control) {
        .query => query(io, alloc, terminal, cmd),
        .display => display(io, alloc, terminal, cmd),
        .delete => delete(io, alloc, terminal, cmd),

        .transmit, .transmit_and_display, .transmit_animation_frame => resp: {
            // If we're transmitting, then our `q` setting value is complicated.
            // The `q` setting inherits the value from the starting command
            // unless `q` is set >= 1 on this command. If it is, then we save
            // that as the new `q` setting.
            const storage = &terminal.screens.active.kitty_images;
            if (storage.loading) |loading| switch (cmd.quiet) {
                // q=0 we use whatever the start command value is
                .no => quiet = loading.quiet,

                // q>=1 we use the new value, but we should already be set to it
                inline .ok, .failures => |tag| {
                    assert(quiet == tag);
                    loading.quiet = tag;
                },
            };

            break :resp switch (cmd.control) {
                .transmit_animation_frame => transmitAnimationFrame(
                    io,
                    alloc,
                    terminal,
                    cmd,
                ),
                else => transmit(
                    io,
                    alloc,
                    terminal,
                    cmd,
                ),
            };
        },

        .control_animation => controlAnimation(
            io,
            alloc,
            terminal,
            cmd,
        ),

        .compose_animation => composeAnimation(
            io,
            alloc,
            terminal,
            cmd,
        ),
    };

    // Handle the quiet settings
    if (resp_) |resp| {
        if (!resp.ok()) {
            log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        }

        return switch (quiet) {
            .no => if (resp.empty()) null else resp,
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
fn query(
    io: std.Io,
    alloc: Allocator,
    terminal: *const Terminal,
    cmd: *const Command,
) Response {
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

    // A query must attempt a complete load, then discard the result without
    // changing image storage.
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#querying-support-and-available-transmission-mediums
    const storage = &terminal.screens.active.kitty_images;
    var loading = LoadingImage.init(io, alloc, cmd, storage.image_limits) catch |err| {
        encodeError(&result, err);
        return result;
    };
    defer loading.deinit(alloc);

    var img = loading.complete(alloc) catch |err| {
        encodeError(&result, err);
        return result;
    };
    img.deinit(alloc);

    return result;
}

/// Transmit image data.
///
/// This loads the image, validates it, and puts it into the terminal
/// screen storage. It does not display the image.
fn transmit(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;

    var result: Response = if (storage.loading) |loading| loading: {
        // Any transmit-like command received while a load is in progress
        // is a continuation chunk of that load, and the load completes
        // according to how it started. If an animation frame load (a=f)
        // is in progress, this chunk belongs to it even when the client
        // didn't repeat a=f on the chunk.
        if (loading.frame != null) return transmitAnimationFrame(
            io,
            alloc,
            terminal,
            cmd,
        );

        break :loading loading.response;
    } else .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    const load = loadAndAddImage(io, alloc, terminal, cmd) catch |err| {
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
        result = display(io, alloc, terminal, &.{
            .control = .{ .display = d_copy },
            .quiet = cmd.quiet,
        });
    }

    // If there are more chunks expected we do not respond.
    if (load.more) return .{};

    // If the loaded image was assigned its ID automatically, not based
    // on a number or explicitly specified ID, then we don't respond.
    if (load.image.metadata.implicit_id) return .{};

    // After the image is added, set the ID in case it changed.
    // The resulting image number and placement ID never change.
    result.id = load.image.id;

    return result;
}

/// Display a previously transmitted image.
fn display(
    io: std.Io,
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

    // A virtual placement (U=1) cannot also be a relative placement.
    // Kitty checks this before even looking up the image.
    if (d.virtual_placement and d.parent_id > 0) {
        result.message = "EINVAL: virtual placement cannot refer to a parent";
        return result;
    }

    // Verify the requested image exists if we have an ID
    const storage = &terminal.screens.active.kitty_images;
    const img_: ?Image = if (d.image_id != 0)
        storage.imageById(d.image_id)
    else
        storage.imageByNumber(d.image_number);
    const img = img_ orelse {
        result.message = "ENOENT: image not found";
        return result;
    };

    // Make sure our response has the image id in case we looked up by number
    result.id = img.id;

    // Location where the placement will go.
    const location: ImageStorage.Placement.Location = location: {
        // Virtual placements are not tracked
        if (d.virtual_placement) break :location .virtual;

        // No parent reference (P=): the placement is pinned to the
        // cursor. The cursor is always tracked but we don't want
        // this pin to move with the cursor.
        if (d.parent_id == 0) {
            const pin = terminal.screens.active.pages.trackPin(
                terminal.screens.active.cursor.page_pin.*,
            ) catch |err| {
                log.warn("failed to create pin for Kitty graphics err={}", .{err});
                result.message = "EINVAL: failed to prepare terminal state";
                return result;
            };
            break :location .{ .pin = pin };
        }

        // A parent reference makes this a relative placement: it is
        // positioned relative to the parent placement instead of the
        // cursor.

        // The key of the placement being created, when it is
        // addressable (an explicit placement ID). Needed for
        // self-parent and cycle detection.
        const child: ?ImageStorage.PlacementKey = if (d.placement_id > 0) .{
            .image_id = img.id,
            .placement_id = .{ .tag = .external, .id = d.placement_id },
        } else null;

        const parent = storage.resolveParent(
            io,
            terminal.screens.active,
            child,
            d.parent_id,
            d.parent_placement_id,
        ) catch |err| {
            result.message = switch (err) {
                error.ParentImageNotFound => "ENOPARENT: parent image not found",
                error.ParentPlacementNotFound => "ENOPARENT: parent placement not found",
                error.SelfParent => "EINVAL: placement cannot be its own parent",
                error.Cycle => "ECYCLE: parent chain creates a cycle",
                error.TooDeep => "ETOODEEP: parent chain too deep",
                error.AncestorNotFound => "ENOENT: parent chain ancestor not found",
            };
            return result;
        };

        break :location .{ .relative = .{
            .parent = parent,
            .horizontal_offset = d.horizontal_offset,
            .vertical_offset = d.vertical_offset,
        } };
    };

    // Add the placement
    const p: ImageStorage.Placement = placement: {
        var p: ImageStorage.Placement = .{
            .location = location,
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

        const cell_offset = p.cellOffset(terminal);
        if (terminal.width_px / terminal.cols > 0) p.x_offset = cell_offset.x;
        if (terminal.height_px / terminal.rows > 0) p.y_offset = cell_offset.y;

        break :placement p;
    };
    storage.addPlacement(
        io,
        alloc,
        terminal.screens.active,
        img.id,
        result.placement_id,
        p,
    ) catch |err| {
        p.deinit(terminal.screens.active);
        encodeError(&result, err);
        return result;
    };

    // Apply cursor movement setting. This only applies to pin placements:
    // relative placements never move the cursor regardless of C=, just
    // like kitty.
    switch (p.location) {
        .virtual, .relative => {},
        .pin => |pin| switch (d.cursor_movement) {
            .none => {},
            .after => {
                // We use terminal.index to properly handle scroll regions.
                const screen = terminal.screens.active;
                const size = p.gridSize(img, terminal);
                const target_x = @as(usize, pin.x) +| @as(usize, size.cols);
                const wraps = target_x >= @as(usize, terminal.cols);
                const requested_rows =
                    (@as(usize, size.rows) -| 1) +| @intFromBool(wraps);

                // The requested row count comes from the application and can
                // be as large as u32. Calling terminal.index once for every
                // row could therefore leave the terminal unresponsive for a
                // very long time.
                //
                // First allow enough calls to reach the bottom of the scroll
                // region. Each call after that scrolls the region by one row,
                // so limit those extra calls to one screen. This follows
                // Kitty's behavior while keeping the amount of work bounded.
                const region = terminal.scrolling_region;
                const rows_before_scroll: usize = if (screen.cursor.y >= region.top and
                    screen.cursor.y <= region.bottom and
                    screen.cursor.x >= region.left and
                    screen.cursor.x <= region.right)
                    @as(usize, region.bottom - screen.cursor.y)
                else
                    0;
                const rows_to_move: usize = @min(
                    requested_rows,
                    rows_before_scroll +| @as(usize, terminal.rows),
                );
                for (0..rows_to_move) |_| terminal.index() catch |err| {
                    log.warn("failed to move cursor: {}", .{err});
                    break;
                };

                // Kitty wraps once when the movement reaches the right edge;
                // otherwise it leaves the cursor immediately to the right of
                // the placement.
                screen.cursor.pending_wrap = false;
                screen.cursorHorizontalAbsolute(
                    if (wraps) 0 else @intCast(target_x),
                );
            },
        },
    }

    return result;
}

/// Transmit animation frame data (a=f).
///
/// Frame data is loaded exactly like image data, including chunking
/// and every transmission medium, and once complete it is composed
/// into a frame of an existing image's animation.
fn transmitAnimationFrame(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const storage = &terminal.screens.active.kitty_images;

    // A chunk arriving while a load is in progress continues that load.
    if (storage.loading) |loading| {
        // If this is the first frame, then we treat it like a normal image
        // because the first frame is just the image.
        if (loading.frame == null) return transmit(
            io,
            alloc,
            terminal,
            cmd,
        );

        // Not the first frame, so continue loading similar to transmit
        // but this is for a subsequent frame.
        var result = loading.response;
        loading.addData(alloc, cmd.data) catch |err| {
            encodeError(&result, err);
            return result;
        };

        // If more chunks are expected we don't respond yet.
        const t = cmd.transmission().?;
        if (t.more_chunks) return .{};

        // Final chunk: copy the loading state out and free the
        // pointer, mirroring loadAndAddImage.
        var loading_copy = loading.*;
        alloc.destroy(loading);
        storage.loading = null;
        defer loading_copy.deinit(alloc);
        return completeAnimationFrame(
            io,
            alloc,
            terminal,
            &loading_copy,
        );
    }

    // We are starting our load, either the first frame or a subsequent frame.
    const f = cmd.control.transmit_animation_frame;
    const t = f.transmission;
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
        // Errors echo the client's frame number; on success this is
        // replaced with the resolved (possibly newly assigned) one.
        .frame = f.edit_frame,
    };

    // A frame can only be added to an existing image.
    if (t.image_id == 0 and t.image_number == 0) {
        result.message = "EINVAL: image ID or number required";
        return result;
    }
    const img = storage.imagePtrByIdOrNumber(
        t.image_id,
        t.image_number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    result.id = img.id;

    var loading = LoadingImage.init(
        io,
        alloc,
        cmd,
        storage.image_limits,
    ) catch |err| {
        encodeError(&result, err);
        return result;
    };
    loading.frame = .{
        .cmd = f,
        .image_generation = img.generation,
    };
    loading.response.id = img.id;

    // Chunked: store the loading state and wait for the rest. The
    // frame parameters above are saved with it; continuation chunks
    // contribute only payload bytes.
    if (t.more_chunks) {
        const loading_ptr = alloc.create(LoadingImage) catch |err| {
            loading.deinit(alloc);
            encodeError(&result, err);
            return result;
        };
        loading_ptr.* = loading;
        storage.loading = loading_ptr;
        return .{};
    }

    defer loading.deinit(alloc);
    return completeAnimationFrame(
        io,
        alloc,
        terminal,
        &loading,
    );
}

/// Complete a fully loaded animation frame: validate it against its
/// image and compose it into the image's animation.
fn completeAnimationFrame(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    loading: *LoadingImage,
) Response {
    const storage = &terminal.screens.active.kitty_images;
    var result = loading.response;
    const f = loading.frame.?.cmd;

    // Re-resolve the image: it may have been deleted, evicted, or
    // replaced while the frame data was being transmitted. The saved
    // generation pins the exact image the load started against.
    var img = storage.imagePtrByIdOrNumber(
        loading.image.id,
        loading.image.number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    if (img.generation != loading.frame.?.image_generation) {
        result.message = "ENOENT: image not found";
        return result;
    }
    if (img.data.bytes() == null) {
        result.message = "EINVAL: image data incomplete";
        return result;
    }

    // Finish decoding the frame data: decompression, PNG decoding,
    // and length validation all match image loading.
    var frame_img = loading.complete(alloc) catch |err| {
        encodeError(&result, err);
        return result;
    };
    defer frame_img.deinit(alloc);

    // The frame rectangle may not exceed the image's size. The x/y
    // offsets are deliberately not validated: composition clips,
    // matching Kitty.
    if (frame_img.width > img.width or frame_img.height > img.height) {
        result.message = "EINVAL: frame dimensions exceed image";
        return result;
    }

    // All composition happens in RGBA; convert both sides as needed.
    if (frame_img.format != .rgba) {
        const rgba = pixel.rgbaFromFormat(
            alloc,
            frame_img.format,
            frame_img.data.bytes().?,
        ) catch |err| {
            encodeError(&result, err);
            return result;
        };
        frame_img.data.deinit(alloc);
        frame_img.data = .{ .complete = rgba };
        frame_img.format = .rgba;
    }
    storage.convertImageToRgba(io, alloc, img) catch |err| {
        encodeError(&result, err);
        return result;
    };

    const anim = ensureAnimation(alloc, img) catch |err| {
        encodeError(&result, err);
        return result;
    };

    // Resolve the frame number: r in 1..count edits that existing
    // frame, anything else (including omitted) creates a new frame
    // appended at count+1. The resolved number is echoed in the
    // response so clients can learn assigned frame numbers.
    const count: u32 = anim.frameCount();
    const number: u32 = number: {
        const r = f.edit_frame;
        if (r == 0 or r > count + 1) break :number count + 1;
        break :number r;
    };
    result.frame = number;

    const src = frame_img.data.bytes().?;
    if (number == count + 1) {
        // Creating a new frame. The gap defaults to 40ms when omitted
        // and a negative gap creates a gapless (never shown) frame.
        const gap: u32 = if (f.gap_ms > 0)
            @intCast(f.gap_ms)
        else if (f.gap_ms < 0)
            0
        else
            animation.default_gap_ms;

        // The base canvas frame must exist before we reserve space.
        if (f.create_frame > 0 and img.frameData(f.create_frame) == null) {
            result.message = "EINVAL: base frame not found";
            return result;
        }

        // Reserve room for the new frame, evicting other images if
        // needed. Eviction can remove images (never this one), so we
        // re-resolve our pointer afterwards to be safe.
        const frame_len: usize = @as(usize, img.width) * img.height * 4;
        const image_id = img.id;
        storage.reserveAnimationBytes(
            io,
            alloc,
            terminal.screens.active,
            image_id,
            frame_len,
        ) catch {
            result.message = "ENOSPC: animation frame storage full";
            return result;
        };
        img = storage.imagePtrByIdOrNumber(image_id, 0).?;

        const canvas = alloc.alloc(u8, frame_len) catch {
            storage.releaseAnimationBytes(frame_len);
            result.message = "ENOMEM: out of memory";
            return result;
        };
        if (f.create_frame > 0) {
            @memcpy(canvas, img.frameData(f.create_frame).?);
        } else {
            pixel.fillBackground(canvas, f.background);
        }
        pixel.composeRect(
            canvas,
            img.width,
            img.height,
            src,
            frame_img.width,
            frame_img.height,
            f.x,
            f.y,
            f.composition_mode,
        );

        anim.frames.append(alloc, .{
            .data = canvas,
            .gap_ms = gap,
        }) catch {
            alloc.free(canvas);
            storage.releaseAnimationBytes(frame_len);
            result.message = "ENOMEM: out of memory";
            return result;
        };

        // A new frame never changes the displayed frame (playback
        // reaches it later), but the storage content changed.
        storage.markMutated(io);
    } else {
        // Editing an existing frame. A nonzero gap also updates the
        // frame's gap; the 40ms default doesn't apply to edits.
        //
        // Unlike frame creation there is no byte reservation here:
        // frames are always stored at full image size, so the edit
        // composes into the existing buffer in place and storage
        // usage cannot change. Kitty likewise exempts frame edits
        // from its quota check.
        if (f.gap_ms != 0) anim.setGapAt(
            number - 1,
            if (f.gap_ms > 0) @intCast(f.gap_ms) else 0,
        );

        // The frame data is owned by this storage, so the const cast
        // is safe (same reasoning as the renderer's image uploads).
        const dst = @constCast(img.frameData(number).?);
        pixel.composeRect(
            dst,
            img.width,
            img.height,
            src,
            frame_img.width,
            frame_img.height,
            f.x,
            f.y,
            f.composition_mode,
        );

        if (number - 1 == anim.current_index) {
            // The displayed pixels changed; restart the frame's gap
            // timer like Kitty's re-upload does.
            anim.frame_shown_at_ms = null;
            storage.markImageContentChanged(io, img);
        } else {
            storage.markMutated(io);
        }
    }

    return result;
}

/// Control animation playback (a=a).
///
/// Successful commands never respond. The only possible responses are
/// for a missing image or identifier. Invalid key values are silently
/// ignored, matching Kitty.
fn controlAnimation(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const a = cmd.control.control_animation;
    const storage = &terminal.screens.active.kitty_images;

    var result: Response = .{
        .id = a.image_id,
        .image_number = a.image_number,
        .placement_id = a.placement_id,
    };
    if (a.image_id == 0 and a.image_number == 0) {
        result.message = "EINVAL: image ID or number required";
        return result;
    }
    const img = storage.imagePtrByIdOrNumber(
        a.image_id,
        a.image_number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };

    const anim = ensureAnimation(alloc, img) catch |err| {
        encodeError(&result, err);
        return result;
    };

    // The keys below are applied independently and in the same order as Kitty.

    // Set a frame's gap (r= together with z=). This is the only way
    // to give the root frame a gap, since it is created gapless.
    if (a.frame != 0 and a.frame <= anim.frameCount() and a.gap_ms != 0) {
        anim.setGapAt(
            a.frame - 1,
            if (a.gap_ms > 0) @intCast(a.gap_ms) else 0,
        );
        storage.markMutated(io);
    }

    // Set the current frame (c=), the client-driven animation
    // primitive.
    if (a.current_frame != 0 and a.current_frame <= anim.frameCount() and
        a.current_frame - 1 != anim.current_index)
    {
        anim.current_index = a.current_frame - 1;
        anim.frame_shown_at_ms = null;
        storage.markImageContentChanged(io, img);
    }

    // Set the playback state (s=). Any state change resets the loop
    // counter; leaving the stopped state restarts the gap timer.
    if (a.action != .invalid) {
        const old = anim.state;
        anim.state = switch (a.action) {
            .invalid => unreachable,
            .stop => .stopped,
            .run_wait => .loading,
            .run => .running,
        };
        if (old == .stopped and anim.state != .stopped) {
            anim.frame_shown_at_ms = null;
        }
        anim.current_loop = 0;
        storage.markMutated(io);
    }

    // Set the loop count (v=), stored off by one per the protocol:
    // v=1 loops forever, v=n plays n-1 loops.
    if (a.loops != 0) {
        anim.max_loops = a.loops - 1;
        storage.markMutated(io);
    }

    // Successful animation control commands never respond.
    return .{};
}

/// Compose a rectangle of pixels from one animation frame onto
/// another (a=c). Frame 1 (the root frame) always exists, so this also works
/// on images without any animation state.
fn composeAnimation(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const c = cmd.control.compose_animation;
    const storage = &terminal.screens.active.kitty_images;

    var result: Response = .{
        .id = c.image_id,
        .image_number = c.image_number,
        .placement_id = c.placement_id,
    };
    if (c.image_id == 0 and c.image_number == 0) {
        result.message = "EINVAL: image ID or number required";
        return result;
    }
    const img = storage.imagePtrByIdOrNumber(
        c.image_id,
        c.image_number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    result.id = img.id;
    if (img.data.bytes() == null) {
        result.message = "EINVAL: image data incomplete";
        return result;
    }

    // Both frames must exist. Note that r is the source frame and c
    // the destination; the spec's reference table describes these
    // backwards (see AnimationFrameComposition).
    if (img.frameData(c.source_frame) == null) {
        result.message = "ENOENT: source frame not found";
        return result;
    }
    if (img.frameData(c.dest_frame) == null) {
        result.message = "ENOENT: destination frame not found";
        return result;
    }

    // Rectangle validation is done in u64 so untrusted 32-bit values
    // can't overflow. Out-of-bounds rectangles are errors here,
    // unlike a=f which clips.
    const width: u64 = if (c.width > 0) c.width else img.width;
    const height: u64 = if (c.height > 0) c.height else img.height;
    if (@as(u64, c.x) + width > img.width or
        @as(u64, c.y) + height > img.height)
    {
        result.message = "EINVAL: destination rectangle out of bounds";
        return result;
    }
    if (@as(u64, c.left_edge) + width > img.width or
        @as(u64, c.top_edge) + height > img.height)
    {
        result.message = "EINVAL: source rectangle out of bounds";
        return result;
    }

    // Composing a frame onto itself requires non-overlapping
    // rectangles.
    if (c.source_frame == c.dest_frame) {
        const x_overlaps = @max(c.left_edge, c.x) < @min(c.left_edge, c.x) + width;
        const y_overlaps = @max(c.top_edge, c.y) < @min(c.top_edge, c.y) + height;
        if (x_overlaps and y_overlaps) {
            result.message = "EINVAL: source and destination rectangles overlap";
            return result;
        }
    }

    // All composition happens in RGBA.
    storage.convertImageToRgba(
        io,
        alloc,
        img,
    ) catch |err| {
        encodeError(&result, err);
        return result;
    };

    // The frame data is owned by this storage, so the const cast is
    // safe. The rectangles were validated disjoint above, so in-place
    // composition within one frame is well-defined.
    const src = img.frameData(c.source_frame).?;
    const dst = @constCast(img.frameData(c.dest_frame).?);
    pixel.composeCanvasRect(
        dst,
        src,
        img.width,
        @intCast(width),
        @intCast(height),
        c.left_edge,
        c.top_edge,
        c.x,
        c.y,
        c.composition_mode,
    );

    // If the destination is the displayed frame then the on-screen
    // content changed.
    const current: u32 = if (img.animation) |anim| anim.current_index else 0;
    if (c.dest_frame - 1 == current) {
        storage.markImageContentChanged(io, img);
    } else {
        storage.markMutated(io);
    }

    return result;
}

/// Get or lazily create the animation state for an image.
fn ensureAnimation(
    alloc: Allocator,
    img: *Image,
) Allocator.Error!*animation.Animation {
    if (img.animation) |anim| return anim;
    const anim = try alloc.create(animation.Animation);
    anim.* = .{};
    img.animation = anim;
    return anim;
}

/// Display a previously transmitted image.
fn delete(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const storage = &terminal.screens.active.kitty_images;

    // Every delete command aborts an incomplete chunked upload.
    if (storage.loading) |loading| {
        loading.destroy(alloc);
        storage.loading = null;
    }

    // Then perform the actual deletion request, too.
    storage.delete(
        io,
        alloc,
        terminal,
        cmd.control.delete.action,
    );

    // Delete never responds on success
    return .{};
}

fn loadAndAddImage(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) !struct {
    image: Image,
    more: bool = false,
    display: ?command.Display = null,
} {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;

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
    } else loading: {
        // Reusing a specific image ID deletes the old image and all of its
        // placements when the new transmission begins, not when it completes.
        if (t.image_id > 0) {
            storage.delete(io, alloc, terminal, .{ .id = .{
                .image_id = t.image_id,
                .delete = true,
            } });
        }

        break :loading try .init(io, alloc, cmd, storage.image_limits);
    };

    // We only want to deinit on error. If we're chunking, then we don't
    // want to deinit at all. If we're not chunking, then we'll deinit
    // after we've copied the image out.
    errdefer loading.deinit(alloc);

    // If the image has no ID, we assign one
    if (loading.image.id == 0) {
        if (loading.image.number > 0) {
            loading.image.id = storage.nextImageId(.explicit);
        } else {
            loading.image.id = storage.nextImageId(.implicit);
            loading.image.metadata.implicit_id = true;
        }
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
    try storage.addImage(io, alloc, terminal.screens.active, img);

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
        error.InsufficientData => r.message = "ENODATA: insufficient data",
        error.InvalidData => r.message = "EINVAL: invalid data",
        error.DecompressionFailed => r.message = "EINVAL: decompression failed",
        error.FilePathTooLong => r.message = "EINVAL: file path too long",
        error.TemporaryFileNotInTempDir => r.message = "EINVAL: temporary file not in temp dir",
        error.TemporaryFileNotNamedCorrectly => r.message = "EINVAL: temporary file not named correctly",
        error.UnsupportedFormat => r.message = "EINVAL: unsupported format",
        error.UnsupportedMedium => r.message = "EINVAL: unsupported medium",
        error.UnsupportedDepth => r.message = "EINVAL: unsupported pixel depth",
        error.DimensionsRequired => r.message = "EINVAL: dimensions required",
        error.DimensionsTooLarge => r.message = "EINVAL: dimensions too large",
    }
}

test "kittygfx query validates image data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var terminal = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);

    var cmd: Command = .{
        .control = .{ .query = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        // A 1x1 RGB image requires three bytes.
        .data = try alloc.dupe(u8, &.{ 0, 0 }),
    };
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &terminal, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: invalid data", resp.message);
    try testing.expectEqual(
        @as(usize, 0),
        terminal.screens.active.kitty_images.images.count(),
    );
}

test "kittygfx valid query does not replace or store image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var terminal = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);
    const storage = &terminal.screens.active.kitty_images;

    // Store a red pixel under the same ID used by the query.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=31;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &terminal, &cmd).?.ok());
    }

    // Successfully validate a black pixel without replacing the red one.
    var cmd: Command = .{
        .control = .{ .query = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, &.{ 0, 0, 0 }),
    };
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &terminal, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(usize, 1), storage.images.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(31).?.data.bytes().?,
    );
}

test "kittygfx image id and number are mutually exclusive for every action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const inputs = [_][]const u8{
        "a=q,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=t,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=T,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=p,i=1,I=2,p=3",
        "a=d,d=a,i=1,I=2,p=3",
        "a=f,i=1,I=2,p=3;AAAA",
        "a=a,i=1,I=2,p=3",
        "a=c,i=1,I=2,p=3",
    };

    for (inputs) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);

        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 3), resp.placement_id);
        try testing.expectEqualStrings(
            "EINVAL: image ID and number are mutually exclusive",
            resp.message,
        );

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=2,p=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
            writer.buffered(),
        );
    }

    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.images.count());
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.placements.count());
}

test "kittygfx conflicting identifiers are rejected before mutation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Store an image so a buggy put would succeed and mutate placement state.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Directly constructed commands must receive the same validation as
    // commands produced by the parser.
    {
        const cmd: Command = .{ .control = .{ .display = .{
            .image_id = 1,
            .image_number = 2,
            .placement_id = 7,
            .cursor_movement = .none,
        } } };
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqual(@as(usize, 0), storage.placements.count());
    }

    // Add a real placement so a buggy delete would remove it.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }

    // q=2 suppresses the required error response but not the validation.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7,q=2",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }
}

test "kittygfx chunked success response uses initial identifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,I=93,p=7,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAAA");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;

        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 93), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=93,p=7;OK\x1b\\",
            writer.buffered(),
        );
    }
}

test "kittygfx chunked error response uses initial identifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=41,p=7,m=1;AA==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AA==");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;

        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 41), resp.id);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqualStrings("EINVAL: invalid data", resp.message);
    }
}

test "kittygfx more chunks with q=1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=1
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=1,s=1,v=2,c=10,r=1,m=1,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk has no q but should respect initial
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx more chunks with q=0" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=0
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk has no q so should respond OK
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
}

test "kittygfx more chunks with chunk increasing q" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=0
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk sets q=1 so should not respond
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx delete aborts chunked image load" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Begin a two-chunk RGB image, then interrupt it with a delete.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,i=1,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);

    {
        const cmd = try command.Parser.parseString(alloc, "a=d");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading == null);

    // A fresh chunked upload must start from empty state after the delete.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,i=1,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAAA");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 6), storage.imageById(1).?.data.len());
}

test "kittygfx uppercase id delete preserves image when placement does not match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Store an unplaced 1x1 RGB image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Uppercase deletion may free data only if the named placement matched.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=I,i=1,p=7",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    try testing.expect(storage.imageById(1) != null);
}

test "kittygfx default format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const storage = &t.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}

test "kittygfx test valid u32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=4294967295",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}

test "kittygfx test valid i32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=1,z=-2147483648",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}

test "kittygfx no response with no image ID or number" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx no response with no image ID or number load and display" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx retransmit same id gets fresh image generation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Transmit a 1x2 RGB image with id=1.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen1 = storage.imageById(1).?.generation;
    try testing.expect(gen1 > 0);
    try testing.expectEqual(gen1, storage.generation);

    // Retransmit the same id with identical dimensions/length. The
    // (width, height, format, len) tuple is identical, so only the
    // generation can reveal that the contents were replaced.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen2 = storage.imageById(1).?.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, storage.generation);
}

test "kittygfx retransmit same id removes existing placements" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();

    // Transmit and display an image, then add anonymous and named placements.
    // Multiple anonymous a=p placements for one image are explicitly valid.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
    try testing.expectEqual(
        tracked + 3,
        t.screens.active.pages.countTrackedPins(),
    );

    // Retransmitting replaces the image and must delete every old placement.
    // Plain a=t creates no replacement placement of its own.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());

    // a=T creates one new placement after deleting the previous image and
    // placements, so repeated redraws remain bounded at one placement.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
}

test "kittygfx retransmit same id removes image on first chunk" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();

    // Store and display the old image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expect(storage.imageById(1) != null);
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );

    // Starting a replacement for the same explicit ID removes the old image
    // and placements before the replacement's final chunk arrives.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "kittygfx delete then retransmit same id gets fresh generation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Transmit and display, then delete everything (including image
    // data), then retransmit the same ID.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,c=1,r=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen1 = storage.imageById(1).?.generation;

    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=A");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
    try testing.expect(storage.imageById(1) == null);
    const gen_delete = storage.generation;
    try testing.expect(gen_delete > gen1);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen2 = storage.imageById(1).?.generation;
    try testing.expect(gen2 > gen1);
    try testing.expect(gen2 > gen_delete);
}

test "kittygfx display clamps cell offsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; // 10 px per col
    t.height_px = 100; // 20 px per row

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=2,r=1,X=99,Y=99,C=1;AAAA",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const storage = &t.screens.active.kitty_images;
    var it = storage.placements.iterator();
    const placement = it.next().?.value_ptr;
    try testing.expectEqual(@as(u32, 9), placement.x_offset);
    try testing.expectEqual(@as(u32, 19), placement.y_offset);

    const actual = placement.pixelSize(storage.imageById(1).?, &t);
    try testing.expectEqual(@as(u32, 11), actual.width);
    try testing.expectEqual(@as(u32, 1), actual.height);
}

test "kittygfx placement bounds cursor movement for untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=4294967295;////",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(usize, 1), t.screens.active.kitty_images.placements.count());
    // Reaching the bottom takes four rows, then scrolling is capped to one
    // screen (five rows), matching Kitty's bounded screen-scroll behavior.
    try testing.expectEqual(@as(usize, 10), t.screens.active.pages.scrollbar().total);
}

test "kittygfx placement moves cursor past a tall image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Load a one-pixel RGB image, then place it over the full width and eight
    // rows. Eight rows are taller than the screen but still within Kitty's
    // scroll budget.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=1,c=5,r=8",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }

    // A subsequent placement begins immediately after the first one instead
    // of overlapping it at the old one-screen movement cap.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=2,C=1",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }

    const storage = &t.screens.active.kitty_images;
    const first = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const second = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const first_pin = switch (first.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    const second_pin = switch (second.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    const first_y = t.screens.active.pages.pointFromPin(
        .screen,
        first_pin.*,
    ).?.screen.y;
    const second_y = t.screens.active.pages.pointFromPin(
        .screen,
        second_pin.*,
    ).?.screen.y;
    try testing.expectEqual(first_y + 8, second_y);
}

test "kittygfx unknown format responds with EINVAL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=42,t=d,i=31,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: unsupported format", resp.message);
    try testing.expectEqual(
        @as(usize, 0),
        t.screens.active.kitty_images.images.count(),
    );
}

test "kittygfx unknown format on query responds with EINVAL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=q,f=42,t=d,i=31,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: unsupported format", resp.message);
}

test "kittygfx zero format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Kitty treats f=0 as an absent f, i.e. RGBA.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=0,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const img = t.screens.active.kitty_images.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}

test "kittygfx unknown format with q=3 has no response" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // q above 2 is out of range in the spec but Kitty suppresses
    // everything for anything above 1, so we must still parse it.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=42,t=d,i=31,q=3,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);

    try testing.expect(execute(io, alloc, &t, &cmd) == null);
}

test "kittygfx out of range display keys are tolerated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=31,s=1,v=1,C=2,U=2;AAAA",
        );
        defer cmd.deinit(alloc);

        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 31), resp.id);
    }

    // U=2 must behave like U=1, so the placement is virtual.
    const storage = &t.screens.active.kitty_images;
    var it = storage.placements.iterator();
    const entry = it.next().?;
    try testing.expect(entry.value_ptr.location == .virtual);
}

test "kittygfx number-based transmission assigns smallest free id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Empty storage: the first free ID is 1, as in Kitty.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=42;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 42), resp.image_number);
    }

    // Occupy ID 2 explicitly; the next number gets 3.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=43;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 3), resp.id);
    }

    // Deleting ID 1 opens a gap that the next number fills.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=I,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=44;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
    }

    try testing.expectEqual(@as(usize, 3), storage.images.count());
    try testing.expectEqual(@as(u32, 44), storage.imageById(1).?.number);
    try testing.expectEqual(@as(u32, 0), storage.imageById(2).?.number);
    try testing.expectEqual(@as(u32, 43), storage.imageById(3).?.number);
}

test "kittygfx number-based id assignment does not replace client image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // A client stores and places a red pixel on the ID the old wrapping
    // counter would assign first.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2147483647;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2147483647,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // A number-based transmission must not collide with it.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=42;AAD/",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
    }

    // The client's image and placement are untouched.
    try testing.expectEqual(@as(usize, 2), storage.images.count());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(2147483647).?.data.bytes().?,
    );
}

test "kittygfx implicit id assignment does not replace client image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // A client stores and places a red pixel on the ID the implicit
    // counter assigns first.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2147483647;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2147483647,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Transmit without an ID or number: no response, and the counter
    // skips over the in-use ID instead of replacing that image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    try testing.expectEqual(@as(usize, 2), storage.images.count());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(2147483647).?.data.bytes().?,
    );
    const implicit = storage.imageById(2147483648).?;
    try testing.expect(implicit.metadata.implicit_id);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, implicit.data.bytes().?);
}

test "kittygfx relative placement with missing parent image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The parent image does not exist: the placement must be rejected
    // with ENOPARENT, nothing may be created, and the cursor must not
    // move (a relative placement never moves the cursor, and a failed
    // one certainly must not).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=1,P=42,Q=1,H=2,V=2",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent image not found",
            resp.message,
        );
    }

    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);
}

test "kittygfx relative placement with missing parent placement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The parent image exists but has no placements at all.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,P=2");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }

    // The parent image has a placement, but not the requested one.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2,p=1,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,P=2,Q=9");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }

    try testing.expectEqual(@as(usize, 1), storage.placements.count());
}

test "kittygfx relative placement cannot parent itself" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Explicitly via Q, and implicitly when the Q=0 fallback selects
    // the placement being replaced.
    for ([_][]const u8{
        "a=p,i=1,p=1,P=1,Q=1",
        "a=p,i=1,p=1,P=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "EINVAL: placement cannot be its own parent",
            resp.message,
        );
    }

    // The original placement must be untouched.
    const storage = &t.screens.active.kitty_images;
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(p.location == .pin);
}

test "kittygfx relative placement cycle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Replacing placement 1 with a parent of placement 2 would create
    // the cycle 1 -> 2 -> 1.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=1,P=1,Q=2");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ECYCLE: parent chain creates a cycle",
            resp.message,
        );
    }

    // The original placement must be untouched, keeping the stored
    // chains acyclic.
    const storage = &t.screens.active.kitty_images;
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(p.location == .pin);
}

test "kittygfx relative placement chain depth limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Chains of up to parent_chain_limit (8) links must work: these
    // placements form the chain 9 -> 8 -> ... -> 2 -> 1.
    for (2..10) |id| {
        var buf: [64]u8 = undefined;
        const cmd = try command.Parser.parseString(
            alloc,
            try std.fmt.bufPrint(&buf, "a=p,i=1,p={},P=1,Q={}", .{ id, id - 1 }),
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // One more link exceeds the limit.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=10,P=1,Q=9");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ETOODEEP: parent chain too deep",
            resp.message,
        );
    }

    const storage = &t.screens.active.kitty_images;
    try testing.expectEqual(@as(usize, 9), storage.placements.count());
}

test "kittygfx relative placement does not move cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // C is left at its default (move after) on the relative placement
    // but it must never move the cursor.
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1,H=3,V=2,c=2,r=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);

    // The stored placement carries the parent link and offsets.
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const rel = p.location.relative;
    try testing.expect(rel.parent.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(@as(i32, 3), rel.horizontal_offset);
    try testing.expectEqual(@as(i32, 2), rel.vertical_offset);
}

test "kittygfx virtual placement with parent rejected before image lookup" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Kitty rejects U=1 + P= before checking that the image exists,
    // so this must not be ENOENT.
    const cmd = try command.Parser.parseString(alloc, "a=p,i=42,U=1,P=1");
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqualStrings(
        "EINVAL: virtual placement cannot refer to a parent",
        resp.message,
    );
}

test "kittygfx deleting a parent deletes relative placements transitively" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Root (pin) <- child <- grandchild
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
        "a=p,i=1,p=3,P=1,Q=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());

    // Deleting the middle placement takes the grandchild with it but
    // leaves the root.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=i,i=1,p=2");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expect(storage.placements.contains(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));

    // Deleting the root removes the remaining placement, and the
    // image itself is retained (lowercase delete).
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=i,i=1,p=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(1) != null);
}

test "kittygfx retransmitting parent image deletes relative placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Image 2's placement is relative to image 1's placement.
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=2,p=1,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 2), storage.placements.count());

    // Retransmitting image 1 removes its placements, which orphans
    // and removes image 2's placement too. Image 2 is left without
    // any placement so it is freed as well: retransmission deletes
    // with uppercase semantics, and kitty also removes an image whose
    // last placement died from a broken parent chain.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(2) == null);
}

test "kittygfx relative placement parent fallback picks lowest external id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
        "a=p,i=1,p=7,C=1",
        "a=p,i=1,p=3,C=1",
        "a=p,i=2,P=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    var it = storage.placements.iterator();
    const rel = while (it.next()) |entry| {
        if (entry.key_ptr.image_id == 2) break entry.value_ptr.location.relative;
    } else return error.PlacementNotFound;
    try testing.expect(rel.parent.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }));
}

test "kittygfx placements created after a full reset are retained" {
    // Regression test: Screen.reset reuses the cursor's tracked pin
    // but PageList.reset marked it garbage. Placements copy the cursor
    // pin, so every placement created after a reset was born garbage
    // and silently swept by the next placement command.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 24, .cols = 80 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    t.fullReset();

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,C=1",
        "a=p,i=1,p=3,P=1,Q=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
}

test "kittygfx relative placement with pruned parent is ENOPARENT" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The parent's tracked content is pruned from history but the
    // placement hasn't been swept yet. The put must reap it and answer
    // ENOPARENT rather than storing an orphan against it.
    const parent = storage.placements.getPtr(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    parent.location.pin.garbage = true;

    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=2,P=1,Q=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}

test "kittygfx uppercase delete frees image of cascaded placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The uppercase delete only matches placement 1. The cascade
    // removes placement 2, leaving the image without placements, so
    // the image must be freed too.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=I,i=1,p=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(1) == null);
}

// Animation tests frequently start from a 1x1 RGB red image with
// id=1 ("/wAA" is FF0000). Composition converts images to RGBA, so
// after the first frame command the base data is FF0000FF.

test "kittygfx animation: new frame with default gap responds with frame number" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Transmit a 1x1 RGB blue frame ("AAD/" is 0000FF).
    const cmd = try command.Parser.parseString(
        alloc,
        "a=f,i=1,f=24,s=1,v=1;AAD/",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(u32, 1), resp.id);
    try testing.expectEqual(@as(u32, 2), resp.frame);

    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try resp.encode(&writer);
    try testing.expectEqualStrings("\x1b_Gi=1,r=2;OK\x1b\\", writer.buffered());

    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.data.bytes().?);

    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 2), anim.frameCount());
    try testing.expectEqual(@as(u32, 0), anim.root_gap_ms);
    try testing.expectEqual(@as(u32, 40), anim.frames.items[0].gap_ms);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, anim.frames.items[0].data);

    // The displayed frame is still the root: renderData is the base.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.renderData().bytes().?);

    // Frame bytes count against the storage total.
    try testing.expectEqual(@as(usize, 8), storage.total_bytes);
}

test "kittygfx animation: frame gap normalization on create" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    for ([_][]const u8{
        "a=f,i=1,f=24,s=1,v=1,z=100;AAD/",
        "a=f,i=1,f=24,s=1,v=1,z=-5;AAD/",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 100), anim.frames.items[0].gap_ms);
    try testing.expectEqual(@as(u32, 0), anim.frames.items[1].gap_ms);
}

test "kittygfx animation: background fill and offset composition" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // 2x1 RGB white image ("////////" is FFFFFF FFFFFF).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // New frame: 1x1 RGB white transmitted at x=1 over an opaque red
    // background (Y=4278190335 is 0xff0000ff, R in the MSB).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,x=1,Y=4278190335;////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 255, 255, 255, 255 },
        anim.frames.items[0].data,
    );
}

test "kittygfx animation: create from base frame with overwrite" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Frame 2 based on the root (c=1) with a semi-transparent blue
    // pixel ("AAD/gA==" is 0000FF80) in overwrite mode: the source
    // replaces the canvas including alpha.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=32,s=1,v=1,c=1,X=1;AAD/gA==",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, anim.frames.items[0].data);
}

test "kittygfx animation: alpha blend composes over base frame" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Blend a fully opaque blue pixel over the root: alpha blending
    // an opaque source is equivalent to a copy.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=32,s=1,v=1,c=1;AAD//w==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Blend a fully transparent pixel over the root: the canvas is
    // unchanged (still the red base).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=32,s=1,v=1,c=1;AAD/AA==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, anim.frames.items[0].data);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, anim.frames.items[1].data);
}

test "kittygfx animation: edit root frame bumps generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const gen1 = storage.imagePtrByIdOrNumber(1, 0).?.generation;

    // r=1 edits the root frame in place. The root is the displayed
    // frame so the image generation must change.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=f,i=1,f=24,s=1,v=1,r=1;AAD/",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(u32, 1), resp.frame);

    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.data.bytes().?);
    try testing.expect(img.generation > gen1);
}

test "kittygfx animation: edit frame gap without data change" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Create frame 2, then edit it with z=-1: gap becomes gapless.
    // Editing with z=0 leaves the gap unchanged (no 40ms default).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,z=77;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,r=2;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 77), anim.frames.items[0].gap_ms);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,r=2,z=-1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(u32, 0), anim.frames.items[0].gap_ms);
}

test "kittygfx animation: frame errors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    const cases = [_]struct {
        input: []const u8,
        message: []const u8,
    }{
        // Unknown image.
        .{
            .input = "a=f,i=9,f=24,s=1,v=1;AAD/",
            .message = "ENOENT: image not found",
        },
        // Frame bigger than the image.
        .{
            .input = "a=f,i=1,f=24,s=2,v=1;////////",
            .message = "EINVAL: frame dimensions exceed image",
        },
        // Nonexistent base frame.
        .{
            .input = "a=f,i=1,f=24,s=1,v=1,c=5;AAD/",
            .message = "EINVAL: base frame not found",
        },
        // Insufficient data for the declared rectangle.
        .{
            .input = "a=f,i=1,f=24,s=1,v=1;AA==",
            .message = "ENODATA: insufficient data",
        },
    };
    for (cases) |case| {
        const cmd = try command.Parser.parseString(alloc, case.input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(case.message, resp.message);
    }

    // None of the failures may have created a frame.
    const storage = &t.screens.active.kitty_images;
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    if (img.animation) |anim| {
        try testing.expectEqual(@as(usize, 0), anim.frames.items.len);
    }
}

test "kittygfx animation: excess frame data is truncated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Six bytes for a 1x1 RGB frame: Kitty tolerates the excess.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=f,i=1,f=24,s=1,v=1;AAD/////",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd).?.ok());

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, anim.frames.items[0].data);
}

test "kittygfx animation: chunked frame transmission" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // 2x1 RGB white image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Transmit a 2x1 frame in two chunks of one pixel each. The
    // chunks repeat a=f per the protocol. No response until the
    // final chunk.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=2,v=1,z=60,m=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);
    {
        const cmd = try command.Parser.parseString(alloc, "a=f,m=0;AAD/");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.frame);
    }
    try testing.expect(storage.loading == null);

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 60), anim.frames.items[0].gap_ms);
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 0, 255, 255 },
        anim.frames.items[0].data,
    );
}

test "kittygfx animation: chunked frame continuation without a=f" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The spec requires chunks to repeat a=f, but a bare continuation
    // (which parses as a transmit action) must still continue the
    // frame load rather than turn into an image transmission.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=2,v=1,m=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAD/");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 2), resp.frame);
    }

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(usize, 1), anim.frames.items.len);
}

test "kittygfx animation: control command sets gap current state and loops" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const gen1 = img.generation;

    // One command can set several things: the root frame's gap
    // (r=1,z=50), the current frame (c=2), the state (s=3, running),
    // and the loop count (v=3, meaning two loops). Successful a=a
    // commands never respond.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=a,i=1,r=1,z=50,c=2,s=3,v=3",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);

    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 50), anim.root_gap_ms);
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expectEqual(animation.Animation.State.running, anim.state);
    try testing.expectEqual(@as(u32, 2), anim.max_loops);

    // Changing the current frame changes the displayed content.
    try testing.expect(img.generation > gen1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.renderData().bytes().?);
}

test "kittygfx animation: control command ignores invalid values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Out-of-range frame numbers and s values are silently ignored.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=a,i=1,r=9,z=50,c=9,s=7",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 0), anim.root_gap_ms);
    try testing.expectEqual(@as(u32, 0), anim.current_index);
    try testing.expectEqual(animation.Animation.State.stopped, anim.state);
}

test "kittygfx animation: control command missing image responds ENOENT" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(alloc, "a=a,i=9,s=3");
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqualStrings("ENOENT: image not found", resp.message);
}

test "kittygfx animation: compose frames" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // 2x1 RGB image: red then blue ("/wAAAAD/" is FF0000 0000FF).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;/wAAAAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    // Frame 2 starts as a transparent canvas with a white pixel at
    // x=0 ("////" is FFFFFF).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Compose the root's pixel at (1,0) onto frame 2 at (0,0):
    // r=1 is the source frame, c=2 the destination, X/Y the source
    // offsets, x/y the destination offsets.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=c,i=1,r=1,c=2,w=1,h=1,X=1,x=0",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 0), resp.frame);
    }

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 255, 255, 0, 0, 0, 0 },
        anim.frames.items[0].data,
    );
}

test "kittygfx animation: compose current frame bumps generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // 2x1 RGB white image; the root frame is the displayed frame.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const gen1 = img.generation;

    // a=c works on images without animation state: both frames are
    // the root. Copy pixel 0 onto pixel 1.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=c,i=1,r=1,c=1,w=1,h=1,x=1",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    try testing.expect(img.generation > gen1);
}

test "kittygfx animation: compose errors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    const cases = [_]struct {
        input: []const u8,
        message: []const u8,
    }{
        .{
            .input = "a=c,i=9,r=1,c=1",
            .message = "ENOENT: image not found",
        },
        .{
            .input = "a=c,i=1,r=2,c=1",
            .message = "ENOENT: source frame not found",
        },
        .{
            .input = "a=c,i=1,r=1,c=2",
            .message = "ENOENT: destination frame not found",
        },
        // 1x1 image: any offset pushes the rect out of bounds.
        .{
            .input = "a=c,i=1,r=1,c=1,x=1",
            .message = "EINVAL: destination rectangle out of bounds",
        },
        .{
            .input = "a=c,i=1,r=1,c=1,X=1",
            .message = "EINVAL: source rectangle out of bounds",
        },
        // Same frame, same (whole-image) rect: overlap.
        .{
            .input = "a=c,i=1,r=1,c=1",
            .message = "EINVAL: source and destination rectangles overlap",
        },
    };
    for (cases) |case| {
        const cmd = try command.Parser.parseString(alloc, case.input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(case.message, resp.message);
    }
}

test "kittygfx animation: delete frame promotes root and fixes current" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Frames 2 and 3: blue and white.
    for ([_][]const u8{
        "a=f,i=1,f=24,s=1,v=1,z=10;AAD/",
        "a=f,i=1,f=24,s=1,v=1,z=20;////",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const total_before = storage.total_bytes;

    // Delete the root frame (r omitted selects it): frame 2 becomes
    // the new root, including its gap. Deletes never respond.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 2), anim.frameCount());
    try testing.expectEqual(@as(u32, 10), anim.root_gap_ms);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.data.bytes().?);
    try testing.expectEqual(total_before - 4, storage.total_bytes);

    // Delete a frame number past the end: clamps to the last frame.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1,r=9");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(u32, 1), anim.frameCount());
    try testing.expectEqual(total_before - 8, storage.total_bytes);

    // Down to one frame: d=f is now a no-op and the image survives.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.imageById(1) != null);
}

test "kittygfx animation: uppercase frame delete removes non-animated image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Transmit and place: unlike d=I, an uppercase frame delete on a
    // non-animated image removes it even though it is placed.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,s=1,v=1,i=1,C=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());

    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=F,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(@as(usize, 0), storage.total_bytes);
}

test "kittygfx animation: deleting current frame refreshes display" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    for ([_][]const u8{
        "a=f,i=1,f=24,s=1,v=1;AAD/",
        "a=f,i=1,f=24,s=1,v=1;////",
        "a=a,i=1,c=3",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        _ = execute(io, alloc, &t, &cmd);
    }

    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 2), anim.current_index);
    const gen1 = img.generation;

    // Deleting the last frame (the current one) clamps the index and
    // refreshes the display.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1,r=3");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(img.generation > gen1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.renderData().bytes().?);
}

test "kittygfx animation: retransmitting base image resets animation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 8), storage.total_bytes);

    // Retransmit the base image: the animation is dropped and the
    // frame bytes are credited back.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    try testing.expect(img.animation == null);
    try testing.expectEqual(@as(usize, 3), storage.total_bytes);
}

test "kittygfx animation: control negative gap makes frame gapless" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    const cmd = try command.Parser.parseString(alloc, "a=a,i=1,r=2,z=-1");
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);

    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 0), anim.frames.items[0].gap_ms);
}
