//! Kitty graphics records: the images, pixels, placements and in-progress
//! chunked load of each screen.
//!
//! A terminal's Kitty graphics live in one image storage per screen. These
//! records carry that storage through a snapshot, so a restored terminal
//! shows the same images in the same places:
//!
//! - KITTY_IMAGE_STORAGE holds one screen's images, its placements on the
//!   pages of its SCREEN sequence, and its in-progress chunked load, if any.
//! - KITTY_IMAGE_PAYLOAD holds the pixels of one image or one animation frame.
//! - KITTY_IMAGE_PAGE_PLACEMENTS holds the placements pinned to one history
//!   page.
//!
//! All of them are optional records. A decoder that does not know them,
//! including any build without Kitty graphics, skips them (see "Unknown
//! Records" in `record.zig`) and restores the same terminal without its
//! images. They are only written when there is something in them, so a
//! terminal without images encodes exactly as it did before these records
//! existed.
//!
//! ## Restoring a Terminal with Images
//!
//! Nothing changes for a caller that uses `snapshot.decode`: the restored
//! terminal has its images, pixels and placements, ready to draw.
//!
//! With `snapshot.Decoder`, the terminal handed back at READY already has
//! every image and placement, but the pixels have not arrived yet. Each
//! image is "pending": it has an ID, a size and places on screen, so the
//! layout is complete, but there is nothing to draw for it. The pixels
//! arrive through `next`, one image or frame per call, mixed in with the
//! history pages. A renderer that checks `Image.renderData` draws an image
//! as soon as its pixels are in, without any other coordination:
//!
//! ```zig
//! var decoded = try decoder.ready(alloc, io, options);
//! defer decoded.deinit(alloc);
//! var terminal = decoded.toOwned();
//! defer terminal.deinit(alloc);
//!
//! // Pending images take part in layout, just not in drawing.
//! const storage = &terminal.screens.active.kitty_images;
//! const image = storage.imageById(1).?;
//! image.renderData().isPending(); // true: nothing to draw yet
//!
//! // Each call restores one history page or one image's pixels.
//! while (try decoder.next(alloc, &terminal)) |progress| switch (progress) {
//!     .image => |p| if (p.image_id == 1) {
//!         image.renderData().isPending(); // false: draw it
//!     },
//!     .page => {},
//! };
//! ```
//!
//! `Decoded.kitty` reports how many images were restored and how many
//! bytes of pixels are still to come, which is enough for a progress bar.
//!
//! ## Where the Records Go
//!
//! ```text
//! +--------------------------------+
//! | SCREEN + PAGE records          |
//! | KITTY_IMAGE_STORAGE (optional) |  after each screen's records
//! +--------------------------------+
//! | CONTINUATION, READY            |
//! +--------------------------------+
//! | KITTY_IMAGE_PAYLOAD (optional) |  per image or frame, anywhere
//! | ...                            |  from here to FINISH
//! +--------------------------------+
//! | HISTORY                        |  per screen
//! | PAGE                           |
//! | KITTY_IMAGE_PAGE_PLACEMENTS    |  optional, after a PAGE with placements
//! | ...                            |
//! +--------------------------------+
//! | FINISH                         |
//! +--------------------------------+
//! ```
//!
//! KITTY_IMAGE_STORAGE comes before READY, so the terminal handed back at
//! READY already knows every image and where it is placed. A placement is
//! pinned to a cell of some page, and where its record goes depends on that
//! page:
//!
//! - Pinned to a page of the SCREEN sequence: KITTY_IMAGE_STORAGE, which
//!   names the page by its position in that sequence.
//! - Pinned to a history page: the KITTY_IMAGE_PAGE_PLACEMENTS record right
//!   after that PAGE. If the decoder has to drop the page, it drops these
//!   placements with it.
//! - Virtual placements, which are drawn through placeholder characters and
//!   have no pin: KITTY_IMAGE_STORAGE.
//! - Relative placements, which are positioned relative to a parent
//!   placement: the same record as their parent, after it. A parent can be
//!   relative itself, so this follows the parents up to the first one that
//!   is pinned or virtual, and uses its record.
//!
//! ## Images
//!
//! KITTY_IMAGE_STORAGE describes each image, including its size, format and
//! any animation, but not its pixels. The decoder adds each image to storage
//! as a pending image (see `ImageStorage.PendingImage`), which reserves the
//! image's full size against the decoder's storage limit. Animation frames
//! are restored pending in the same way. A pending image can be placed and
//! queried like any other image. It just isn't drawn yet.
//!
//! Images are written oldest first. The decoder adds them in that order, so
//! when the decoder's limit is smaller than the encoder's, older images are
//! evicted to make room for newer ones, exactly as live transmissions would
//! evict them.
//!
//! Image generations are never written. They are only meaningful within
//! one process, so the decoder stamps fresh ones as it adds each image.
//!
//! ## Pixels
//!
//! The pixels come after READY, one KITTY_IMAGE_PAYLOAD record per image or
//! frame, so a restored terminal can be shown before they arrive. Each
//! payload names its screen and image, and completes that pending image or
//! frame. An animation does not play until all of its frames have arrived.
//!
//! A payload may come anywhere after READY and before FINISH, in any order,
//! with one exception: it never comes between a PAGE and that page's
//! KITTY_IMAGE_PAGE_PLACEMENTS, which must follow the page directly. This
//! leaves encoders free to choose the order. One could send each image's
//! pixels right after the history page that first shows it, for example, so
//! that large images deep in scrollback don't hold up recent history.
//!
//! This encoder writes payloads where the reader needs them soonest:
//!
//! 1. Right after READY, the images placed in the viewport of the screen
//!    that is shown, so what is on screen can be drawn first. For each
//!    image, the frame it shows comes before its other frames.
//! 2. Right after each history page's KITTY_IMAGE_PAGE_PLACEMENTS, the
//!    images first placed on that page, so an image in scrollback arrives
//!    with the text around it, and a large one deep in scrollback doesn't
//!    hold up the recent history before it.
//! 3. After all history, everything else: images in the viewport of a
//!    screen that is not shown, then images that are not placed where the
//!    reader can see them. Nothing waits on these.
//!
//! Live input may delete an image before its payload arrives, or send a
//! new image with the same ID. The payload is then dropped rather than
//! attached to whatever image now has that ID.
//!
//! Payloads carry the pixels as they are, with no compression of their
//! own. A snapshot is normally compressed on its way to the reader, and on
//! real images that compressor does at least as well on raw pixels as it
//! would on pixels that were compressed first. Compressing them here would
//! only add encoder time, and everything after the pixels would wait for
//! it.
//!
//! The in-progress load is the one place where image data comes before
//! READY. It carries every byte received so far, because the next chunk
//! from live input is appended to them. A snapshot taken partway through a
//! large transmission can therefore hold megabytes of image data in
//! KITTY_IMAGE_STORAGE. Snapshots taken mid-transmission are rare, so this
//! cost is accepted.
//!
//! All integers are little-endian.
//!
//! ## Binary Format
//!
//! ### KITTY_IMAGE_STORAGE
//!
//! ```text
//!   0 +------------------------------------+
//!     | Screen key (u16)                   |
//!   2 +------------------------------------+
//!     | Next image ID (u32)                |
//!   6 +------------------------------------+
//!     | Next internal placement ID (u32)   |
//!  10 +------------------------------------+
//!     | Image count (u32)                  |
//!  14 +------------------------------------+
//!     | Placement count (u32)              |
//!  18 +------------------------------------+
//!     | In-progress load present (u8)      |
//!  19 +------------------------------------+
//!     | Image * image count                |
//!     +------------------------------------+
//!     | Placement * placement count        |
//!     +------------------------------------+
//!     | In-progress load, when present     |
//! end +------------------------------------+
//! ```
//!
//! Images are ordered oldest first. Placements are ordered so every parent
//! precedes its relative children.
//!
//! #### Image
//!
//! ```text
//!   0 +------------------------------------+
//!     | ID (u32)                           |
//!   4 +------------------------------------+
//!     | Number (u32)                       |
//!   8 +------------------------------------+
//!     | Width (u32)                        |
//!  12 +------------------------------------+
//!     | Height (u32)                       |
//!  16 +------------------------------------+
//!     | Format (u8)                        |
//!  17 +------------------------------------+
//!     | Flags (u8)                         |
//!  18 +------------------------------------+
//!     | Decoded byte length (u64)          |
//!  26 +------------------------------------+
//!     | Animation present (u8)             |
//!  27 +------------------------------------+
//!     | Animation, when present            |
//! end +------------------------------------+
//! ```
//!
//! Formats are 0 rgb, 1 rgba, 2 png, 3 gray_alpha and 4 gray. Stored images
//! are never png. Flag bit 0 is the transient usage hint, and bit 1 marks
//! an automatically assigned ID. The other bits are zero. The decoded length
//! is width * height * bytes per pixel.
//!
//! #### Animation
//!
//! ```text
//!   0 +------------------------------------+
//!     | State (u8)                         |
//!   1 +------------------------------------+
//!     | Max loops (u32)                    |
//!   5 +------------------------------------+
//!     | Current loop (u32)                 |
//!   9 +------------------------------------+
//!     | Current frame index (u32)          |
//!  13 +------------------------------------+
//!     | Root frame gap ms (u32)            |
//!  17 +------------------------------------+
//!     | Frame count (u32)                  |
//!  21 +------------------------------------+
//!     | Frame * frame count                |
//! end +------------------------------------+
//!
//! Frame:
//!   0 +------------------------------------+
//!     | Gap ms (u32)                       |
//!   4 +------------------------------------+
//!     | Decoded byte length (u64)          |
//!  12 +------------------------------------+
//! ```
//!
//! States are 0 stopped, 1 loading and 2 running. The frame count excludes
//! the root frame, which is the image itself. A frame's decoded length is
//! width * height * 4. The time the current frame was shown is not encoded;
//! playback re-anchors on the decoder's clock.
//!
//! #### Placement
//!
//! ```text
//!   0 +------------------------------------+
//!     | Image ID (u32)                     |
//!   4 +------------------------------------+
//!     | Placement ID tag (u8)              |
//!   5 +------------------------------------+
//!     | Placement ID (u32)                 |
//!   9 +------------------------------------+
//!     | Location kind (u8)                 |
//!  10 +------------------------------------+
//!     | Location                           |
//!     +------------------------------------+
//!     | X offset, Y offset (u32 * 2)       |
//!     +------------------------------------+
//!     | Source x, y, width, height         |
//!     | (u32 * 4)                          |
//!     +------------------------------------+
//!     | Columns, rows (u32 * 2)            |
//!     +------------------------------------+
//!     | Z (i32)                            |
//! end +------------------------------------+
//! ```
//!
//! Placement ID tags are 0 internal and 1 external. Location kinds and their
//! locations are:
//!
//! - 0 pin: in KITTY_IMAGE_STORAGE, page index within the screen's SCREEN
//!   sequence (u16), then y (u16) and x (u16) within that page. In
//!   KITTY_IMAGE_PAGE_PLACEMENTS, only y (u16) and x (u16) within the
//!   preceding history page.
//! - 1 virtual: no location bytes. KITTY_IMAGE_STORAGE only.
//! - 2 relative: parent image ID (u32), parent placement ID tag (u8), parent
//!   placement ID (u32), horizontal offset (i32), vertical offset (i32).
//!
//! #### In-progress load
//!
//! A chunked transmission that was cut off between two chunks. The decoder
//! installs it, so the next chunk from live input continues it.
//!
//! ```text
//! +------------------------------------+
//! | ID, number, width, height (u32 * 4)|
//! | Format (u8)                        |
//! | Compression (u8)                   |
//! | Flags (u8)                         |
//! | Quiet (u8)                         |
//! | Response ID, image number,         |
//! | placement ID, frame (u32 * 4)      |
//! | Display present (u8)               |
//! | Display, when present              |
//! | Frame present (u8)                 |
//! | Frame, when present                |
//! | Received byte count (u32)          |
//! | Received bytes                     |
//! +------------------------------------+
//! ```
//!
//! Format and flags are as for images, except that a load may be png.
//! Compression is 0 none or 1 zlib. Quiet is 0 no, 1 ok or 2 failures. The
//! received bytes are the chunk data received so far, before any
//! decompression or png decoding.
//!
//! Display is the placement to create once the load completes:
//!
//! - Image ID, image number, placement ID, x, y, width, height, x offset,
//!   y offset, columns and rows (u32 each).
//! - Cursor movement (u8): 0 after, 1 none.
//! - Virtual (u8): 1 for a virtual placement.
//! - Parent ID and parent placement ID (u32 each).
//! - Horizontal offset, vertical offset and z (i32 each).
//!
//! Frame is present when the load is an animation frame rather than a new
//! image:
//!
//! - Format (u8), as for the load.
//! - Medium (u8): 0 direct, 1 file, 2 temporary file, 3 shared memory.
//! - Width, height, size, offset, image ID, image number and placement ID
//!   (u32 each).
//! - Compression (u8), as for the load.
//! - More chunks (u8).
//! - Usage flags (u32).
//! - X, y, base frame and edited frame (u32 each).
//! - Gap in milliseconds (i32).
//! - Composition mode (u8): 0 alpha blend, 1 overwrite.
//! - Background color (u32).
//!
//! ### KITTY_IMAGE_PAYLOAD
//!
//! ```text
//!   0 +------------------------------------+
//!     | Screen key (u16)                   |
//!   2 +------------------------------------+
//!     | Image ID (u32)                     |
//!   6 +------------------------------------+
//!     | Frame number (u32)                 |
//!  10 +------------------------------------+
//!     | Byte length (u64)                  |
//!  18 +------------------------------------+
//!     | Pixels                             |
//! end +------------------------------------+
//! ```
//!
//! Frames are numbered as the Kitty graphics protocol numbers them. Frame 1
//! is the image itself, so its byte length is the image's decoded length.
//! Frames 2 and up are animation frames, whose byte length is
//! width * height * 4. The pixels are exactly that many bytes, and the
//! record ends with them.
//!
//! ### KITTY_IMAGE_PAGE_PLACEMENTS
//!
//! ```text
//! 0 +------------------------------------+
//!   | Screen key (u16)                   |
//! 2 +------------------------------------+
//!   | Placement count (u32)              |
//! 6 +------------------------------------+
//!   | Placement * placement count        |
//!   +------------------------------------+
//! ```

const std = @import("std");
const build_options = @import("terminal_options");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const io = @import("io.zig");
const record = @import("record.zig");
const terminal_kitty = @import("../kitty.zig");
const graphics_command = @import("../kitty/graphics_command.zig");
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;

const graphics = terminal_kitty.graphics;
const Image = graphics.Image;
const LoadingImage = graphics.LoadingImage;
const Animation = graphics.Animation;
const ImageStorage = graphics.ImageStorage;
const Placement = ImageStorage.Placement;
const PlacementKey = ImageStorage.PlacementKey;
const PlacementId = ImageStorage.PlacementId;
const Node = TerminalPageList.List.Node;

const log = std.log.scoped(.snapshot_kitty);

/// Errors possible while encoding Kitty graphics records.
pub const EncodeError = Allocator.Error || record.Writer.FinishError;

/// Errors possible while decoding Kitty graphics records.
pub const DecodeError = Allocator.Error ||
    std.Io.Reader.Error ||
    record.Reader.FinishError ||
    error{
        /// The record is valid but not the expected kind.
        UnexpectedRecordTag,

        /// The record names an unknown screen, or a different screen from
        /// the one whose records it follows.
        UnexpectedKittyKey,
    };

/// Read and validate a screen key.
fn decodeKey(reader: *std.Io.Reader) DecodeError!TerminalScreenKey {
    const raw = try io.readInt(reader, u16);
    const Tag = @typeInfo(TerminalScreenKey).@"enum".tag_type;
    const value = std.math.cast(Tag, raw) orelse
        return error.UnexpectedKittyKey;
    return std.enums.fromInt(TerminalScreenKey, value) orelse
        error.UnexpectedKittyKey;
}

fn encodeKey(writer: *std.Io.Writer, key: TerminalScreenKey) !void {
    try io.writeInt(writer, u16, @intCast(@backingInt(key)));
}

/// Image pixel formats on the wire.
const Format = graphics_command.Transmission.Format;

fn encodeFormat(format: Format) u8 {
    return switch (format) {
        .rgb => 0,
        .rgba => 1,
        .png => 2,
        .gray_alpha => 3,
        .gray => 4,
    };
}

fn decodeFormat(raw: u8) ?Format {
    return switch (raw) {
        0 => .rgb,
        1 => .rgba,
        2 => .png,
        3 => .gray_alpha,
        4 => .gray,
        else => null,
    };
}

/// Image flags shared by images and the in-progress load.
const ImageFlags = packed struct(u8) {
    transient: bool = false,
    implicit_id: bool = false,
    _padding: u6 = 0,
};

fn imageFlags(img: *const Image) ImageFlags {
    return .{
        .transient = img.metadata.transient,
        .implicit_id = img.metadata.implicit_id,
    };
}

/// The decoded byte length of an image, or null when its dimensions or
/// format cannot describe stored pixels.
fn imageLen(width: u32, height: u32, format: Format) ?usize {
    if (width == 0 or height == 0) return null;
    if (format == .png) return null;
    const bpp = graphics_command.Transmission.formatBpp(format);
    return std.math.mul(usize, @as(usize, width) * height, bpp) catch null;
}

// ---------------------------------------------------------------------------
// Encoding

/// One placement, together with its root: the placement that decides
/// where it is encoded. A pinned or virtual placement is its own root. A
/// relative placement's root is the first placement up its parent chain
/// that is pinned or virtual.
const PlannedPlacement = struct {
    key: PlacementKey,
    placement: *const Placement,

    /// How many parents lie between this placement and its root. Zero for
    /// a root. Sorting by depth writes parents before their children.
    depth: u32,

    /// Where the root is pinned, or null when the root is virtual.
    root: ?RootPin,

    const RootPin = struct {
        node: *Node,

        /// The page's position in the screen's page list, counting from
        /// zero at the oldest page.
        ordinal: u32,

        y: u16,
        x: u16,
    };
};

/// Orders placement keys by image ID, then placement ID. This is the
/// final tiebreak in every placement order, so the encoding never depends
/// on hash map order.
fn keyLessThan(lhs: PlacementKey, rhs: PlacementKey) bool {
    if (lhs.image_id != rhs.image_id) return lhs.image_id < rhs.image_id;
    const lhs_tag = @backingInt(lhs.placement_id.tag);
    const rhs_tag = @backingInt(rhs.placement_id.tag);
    if (lhs_tag != rhs_tag) return lhs_tag < rhs_tag;
    return lhs.placement_id.id < rhs.placement_id.id;
}

/// One KITTY_IMAGE_PAYLOAD record to encode, and when to write it.
const PlannedPayload = struct {
    image: *const Image,

    /// The frame number, as the Kitty graphics protocol counts frames. 1 is
    /// the image itself and 2 and up are its animation frames.
    frame: u32,

    /// Which part of the snapshot the payload is written in.
    stage: Stage,

    /// For `.history`, the page the image is first placed on and that
    /// page's ordinal. The payload is written right after that page. Zero
    /// and null otherwise.
    node: ?*const Node,
    ordinal: u32,

    /// True for the frame the image shows right now, which is the only
    /// one a renderer needs to draw it. See `Image.renderData`.
    displayed: bool,

    /// The image's position in `ScreenPlan.images`, oldest first.
    image_index: u32,

    const Stage = enum(u2) {
        /// The image is placed in the viewport. Written right after READY,
        /// so what is on screen fills in first.
        viewport,

        /// The image is placed on a history page. Written right after that
        /// page's KITTY_IMAGE_PAGE_PLACEMENTS, so images in scrollback
        /// arrive with the text around them and don't hold up the history
        /// pages before them.
        history,

        /// Everything else: images that are not placed, placed outside the
        /// viewport on an active page, or on a screen that is not shown.
        /// Written after all history, where nothing waits on them.
        remaining,
    };

    /// The pixels to encode.
    fn bytes(self: PlannedPayload) []const u8 {
        return switch (self.frame) {
            1 => self.image.data.bytes().?,
            else => self.image.animation.?.frames.items[self.frame - 2].data,
        };
    }

    /// The order payloads are written in: by stage, then newest history
    /// page first, then the displayed frame of every image before the other
    /// frames, then oldest image first, then by frame.
    fn lessThan(_: void, lhs: PlannedPayload, rhs: PlannedPayload) bool {
        if (lhs.stage != rhs.stage) {
            return @backingInt(lhs.stage) < @backingInt(rhs.stage);
        }
        if (lhs.ordinal != rhs.ordinal) return lhs.ordinal > rhs.ordinal;
        if (lhs.displayed != rhs.displayed) return lhs.displayed;
        if (lhs.image_index != rhs.image_index) {
            return lhs.image_index < rhs.image_index;
        }
        return lhs.frame < rhs.frame;
    }
};

/// `ScreenPlan` in builds with Kitty graphics, otherwise `void`, so callers
/// can name the type unconditionally.
pub const Plan = if (build_options.kitty_graphics) ScreenPlan else void;

/// Everything needed to encode one screen's Kitty graphics records, worked
/// out once before encoding starts.
///
/// Encoding a screen's Kitty graphics takes more than one pass over its
/// storage. Images must be written oldest first, and placements must be
/// sorted so parents come before children and split by the page they are
/// pinned to. Pixel payloads are ordered so that what the reader can see
/// arrives first (see `PlannedPayload.Stage`). The plan does that work up
/// front, and then writes each record where it belongs:
///
/// - `encodeStorage` right after the screen's SCREEN records.
/// - `encodeViewportPayloads` after READY.
/// - `encodePagePlacements` right after each history page.
/// - `encodeRemainingPayloads` after all history.
///
/// `init` returns null when the screen has no images and no in-progress
/// load. The snapshot then has no Kitty graphics records for that screen at
/// all, so a terminal without images encodes exactly as it did before these
/// records existed.
///
/// ```zig
/// var plan = (try kitty.ScreenPlan.init(alloc, screen, .primary)) orelse return;
/// defer plan.deinit();
/// try plan.encodeStorage(&stream);
/// // ... after READY ...
/// try plan.encodeViewportPayloads(&stream);
/// // ... later, while encoding HISTORY ...
/// try plan.encodePagePlacements(history_page, &stream);
/// // ... after all history ...
/// try plan.encodeRemainingPayloads(&stream);
/// ```
pub const ScreenPlan = struct {
    alloc: Allocator,
    screen: *const TerminalScreen,
    key: TerminalScreenKey,

    /// Every image, oldest first.
    images: []*const Image,

    /// Placements for KITTY_IMAGE_STORAGE: those rooted on a page of the SCREEN
    /// sequence, plus virtual ones. Parents come first.
    resident: []PlannedPlacement,

    /// Placements for KITTY_IMAGE_PAGE_PLACEMENTS: those rooted on a history
    /// page. Grouped by page, newest page first to match HISTORY, with
    /// parents first within each page.
    history: []PlannedPlacement,

    /// The next entry in `history` that `encodePagePlacements` has not
    /// written yet.
    history_next: usize,

    /// The position of the SCREEN sequence's first page in the screen's
    /// page list. Pages before it are history. See `RootPin.ordinal`.
    first_resident: u32,

    /// KITTY_IMAGE_PAYLOAD records in the order they are written: the
    /// viewport stage, then the history stage grouped by page newest
    /// first, then the rest. See `PlannedPayload`.
    payloads: []PlannedPayload,

    /// Where the history stage starts and ends in `payloads`.
    history_payloads: struct { start: usize, end: usize },

    /// The next history-stage payload that `encodePagePlacements` has not
    /// written yet.
    payload_next: usize,

    /// Plan the Kitty graphics records for `screen`, which the snapshot
    /// names `key`. Returns null if there is nothing to encode. The plan
    /// points into the screen's storage, so the screen must not change
    /// until `deinit`.
    pub fn init(
        alloc: Allocator,
        screen: *const TerminalScreen,
        key: TerminalScreenKey,
    ) Allocator.Error!?ScreenPlan {
        const storage = &screen.kitty_images;
        if (storage.images.count() == 0 and storage.loading == null) {
            return null;
        }

        // Images oldest first: the decoder restores them in this order and
        // stamps increasing generations, preserving eviction age.
        const images = try alloc.alloc(*const Image, storage.images.count());
        errdefer alloc.free(images);
        {
            var it = storage.images.valueIterator();
            var i: usize = 0;
            while (it.next()) |img| : (i += 1) images[i] = img;
            std.sort.pdq(*const Image, images, {}, struct {
                fn lessThan(_: void, lhs: *const Image, rhs: *const Image) bool {
                    if (lhs.generation != rhs.generation) {
                        return lhs.generation < rhs.generation;
                    }
                    return lhs.id < rhs.id;
                }
            }.lessThan);
        }

        // Page ordinals locate pinned roots: resident pages for
        // KITTY_IMAGE_STORAGE and history pages for
        // KITTY_IMAGE_PAGE_PLACEMENTS.
        var ordinals: std.AutoHashMapUnmanaged(*Node, u32) = .empty;
        defer ordinals.deinit(alloc);
        const first_resident_node = screen.pages.getTopLeft(.active).node;
        var first_resident: u32 = 0;
        {
            var node = screen.pages.pages.first;
            var ordinal: u32 = 0;
            while (node) |current| : ({
                node = current.next;
                ordinal += 1;
            }) {
                if (current == first_resident_node) first_resident = ordinal;
                try ordinals.put(alloc, current, ordinal);
            }
        }

        var resident: std.ArrayList(PlannedPlacement) = .empty;
        defer resident.deinit(alloc);
        var history: std.ArrayList(PlannedPlacement) = .empty;
        defer history.deinit(alloc);

        var it = storage.placements.iterator();
        while (it.next()) |entry| {
            const planned = plan(
                storage,
                &ordinals,
                entry.key_ptr.*,
                entry.value_ptr,
            ) orelse continue;
            if (planned.root) |root| {
                if (root.ordinal < first_resident) {
                    try history.append(alloc, planned);
                    continue;
                }
            }
            try resident.append(alloc, planned);
        }
        std.sort.pdq(PlannedPlacement, resident.items, {}, residentLessThan);
        std.sort.pdq(PlannedPlacement, history.items, {}, historyLessThan);

        const payloads = try planPayloads(
            alloc,
            screen,
            images,
            resident.items,
            history.items,
        );
        errdefer alloc.free(payloads);
        const history_start = for (payloads, 0..) |payload, i| {
            if (payload.stage != .viewport) break i;
        } else payloads.len;
        const history_end = for (payloads[history_start..], history_start..) |payload, i| {
            if (payload.stage != .history) break i;
        } else payloads.len;

        const resident_slice = try resident.toOwnedSlice(alloc);
        errdefer alloc.free(resident_slice);
        const history_slice = try history.toOwnedSlice(alloc);

        return .{
            .alloc = alloc,
            .screen = screen,
            .key = key,
            .images = images,
            .resident = resident_slice,
            .history = history_slice,
            .history_next = 0,
            .first_resident = first_resident,
            .payloads = payloads,
            .history_payloads = .{ .start = history_start, .end = history_end },
            .payload_next = history_start,
        };
    }

    /// Free the plan. The screen is not affected.
    pub fn deinit(self: *ScreenPlan) void {
        self.alloc.free(self.images);
        self.alloc.free(self.resident);
        self.alloc.free(self.history);
        self.alloc.free(self.payloads);
        self.* = undefined;
    }

    /// The order of `resident`. These placements share one record, so
    /// their pages don't matter: parents first, then by key.
    fn residentLessThan(
        _: void,
        lhs: PlannedPlacement,
        rhs: PlannedPlacement,
    ) bool {
        if (lhs.depth != rhs.depth) return lhs.depth < rhs.depth;
        return keyLessThan(lhs.key, rhs.key);
    }

    /// The order of `history`: grouped by page, newest page first to match
    /// the order HISTORY writes its pages, then parents first, then by key.
    fn historyLessThan(
        _: void,
        lhs: PlannedPlacement,
        rhs: PlannedPlacement,
    ) bool {
        const lhs_ordinal = lhs.root.?.ordinal;
        const rhs_ordinal = rhs.root.?.ordinal;
        if (lhs_ordinal != rhs_ordinal) return lhs_ordinal > rhs_ordinal;
        if (lhs.depth != rhs.depth) return lhs.depth < rhs.depth;
        return keyLessThan(lhs.key, rhs.key);
    }

    /// Find one placement's root (see `PlannedPlacement`). Returns null
    /// when the placement can't be located and is left out of the
    /// snapshot: its root's pin was pruned, a parent is missing, or its
    /// parents form a loop.
    fn plan(
        storage: *const ImageStorage,
        ordinals: *const std.AutoHashMapUnmanaged(*Node, u32),
        key: PlacementKey,
        placement: *const Placement,
    ) ?PlannedPlacement {
        var depth: u32 = 0;
        var current = placement;
        while (true) switch (current.location) {
            .relative => |rel| {
                // A chain longer than the placement count must loop.
                depth += 1;
                if (depth > storage.placements.count()) return null;
                current = storage.placements.getPtr(rel.parent) orelse
                    return null;
            },

            .virtual => return .{
                .key = key,
                .placement = placement,
                .depth = depth,
                .root = null,
            },

            .pin => |pin| {
                if (pin.garbage) return null;
                return .{
                    .key = key,
                    .placement = placement,
                    .depth = depth,
                    .root = .{
                        .node = pin.node,
                        .ordinal = ordinals.get(pin.node) orelse return null,
                        .y = pin.y,
                        .x = pin.x,
                    },
                };
            },
        };
    }

    /// Encode the KITTY_IMAGE_STORAGE record. Call this right after the
    /// screen's SCREEN and PAGE records, which is where decoders look for it.
    pub fn encodeStorage(
        self: *const ScreenPlan,
        destination: *record.Writer,
    ) EncodeError!void {
        const storage = &self.screen.kitty_images;
        const writer = destination.begin(.kitty_image_storage);
        errdefer destination.cancel();

        try encodeKey(writer, self.key);
        try io.writeInt(writer, u32, storage.next_image_id);
        try io.writeInt(writer, u32, storage.next_internal_placement_id);
        try io.writeInt(writer, u32, @intCast(self.images.len));
        try io.writeInt(writer, u32, @intCast(self.resident.len));
        try writer.writeByte(@intFromBool(storage.loading != null));

        for (self.images) |img| try encodeImage(writer, img);
        for (self.resident) |planned| {
            try encodePlacement(
                writer,
                planned,
                .{ .storage = self.first_resident },
            );
        }
        if (storage.loading) |loading| try encodeLoading(writer, loading);

        try destination.finish();
    }

    /// Plan a payload for every image and frame whose pixels are present,
    /// sorted into the order they are written. See `PlannedPayload`.
    fn planPayloads(
        alloc: Allocator,
        screen: *const TerminalScreen,
        images: []const *const Image,
        resident: []const PlannedPlacement,
        history: []const PlannedPlacement,
    ) Allocator.Error![]PlannedPayload {
        // Where each placed image goes: in the viewport, or on the newest
        // history page it is placed on.
        const Where = struct { stage: PlannedPayload.Stage, node: ?*const Node, ordinal: u32 };
        var placed: std.AutoHashMapUnmanaged(u32, Where) = .empty;
        defer placed.deinit(alloc);

        // The viewport may be scrolled into history, so every placement is
        // checked against it. An image placed more than once takes the
        // earliest stage of any of its placements, and among history
        // placements the newest page, which comes first.
        const Group = struct { items: []const PlannedPlacement, stage: PlannedPayload.Stage };
        for ([_]Group{
            .{ .items = resident, .stage = .remaining },
            .{ .items = history, .stage = .history },
        }) |group| for (group.items) |planned| {
            const candidate: Where = candidate: {
                // A virtual placement is drawn wherever its placeholder
                // characters are, which is usually on screen.
                const root = planned.root orelse break :candidate .{
                    .stage = .viewport,
                    .node = null,
                    .ordinal = 0,
                };
                const pin: TerminalPageList.Pin = .{
                    .node = root.node,
                    .y = root.y,
                    .x = root.x,
                };
                if (screen.pages.pointFromPin(.viewport, pin) != null) {
                    break :candidate .{ .stage = .viewport, .node = null, .ordinal = 0 };
                }
                break :candidate switch (group.stage) {
                    .history => .{
                        .stage = .history,
                        .node = root.node,
                        .ordinal = root.ordinal,
                    },
                    else => .{ .stage = .remaining, .node = null, .ordinal = 0 },
                };
            };
            const gop = try placed.getOrPut(alloc, planned.key.image_id);
            if (!gop.found_existing or
                @backingInt(candidate.stage) < @backingInt(gop.value_ptr.stage))
            {
                gop.value_ptr.* = candidate;
            }
        };

        var result: std.ArrayList(PlannedPayload) = .empty;
        errdefer result.deinit(alloc);
        for (images, 0..) |img, index| {
            const where: Where = placed.get(img.id) orelse
                .{ .stage = .remaining, .node = null, .ordinal = 0 };

            // The displayed frame is the current animation frame, or the
            // image itself.
            const displayed: u32 = if (img.animation) |anim|
                anim.current_index + 1
            else
                1;

            const frame_count: u32 = if (img.animation) |anim|
                @intCast(anim.frames.items.len + 1)
            else
                1;
            for (1..frame_count + 1) |number| {
                const frame: u32 = @intCast(number);
                const present = switch (frame) {
                    1 => !img.data.isPending(),
                    else => !img.animation.?.frames.items[frame - 2].isPending(),
                };
                if (!present) continue;
                try result.append(alloc, .{
                    .image = img,
                    .frame = frame,
                    .stage = where.stage,
                    .node = where.node,
                    .ordinal = where.ordinal,
                    .displayed = frame == displayed,
                    .image_index = @intCast(index),
                });
            }
        }
        std.sort.pdq(PlannedPayload, result.items, {}, PlannedPayload.lessThan);
        return result.toOwnedSlice(alloc);
    }

    /// Encode a KITTY_IMAGE_PAYLOAD record for each image placed in the
    /// viewport, or nothing when there are none. Call this after READY.
    /// For the screen that is shown, call it first thing after READY so the
    /// reader can draw what is on screen as soon as possible.
    pub fn encodeViewportPayloads(
        self: *const ScreenPlan,
        destination: *record.Writer,
    ) EncodeError!void {
        for (self.payloads[0..self.history_payloads.start]) |payload| {
            try encodePayload(destination, self.key, payload);
        }
    }

    /// Encode a KITTY_IMAGE_PAYLOAD record for each image and frame whose
    /// pixels have not been written by `encodeViewportPayloads` or
    /// `encodePagePlacements`. Call this after the screen's HISTORY, which
    /// must have been encoded with this plan.
    pub fn encodeRemainingPayloads(
        self: *const ScreenPlan,
        destination: *record.Writer,
    ) EncodeError!void {
        assert(self.payload_next == self.history_payloads.end);
        for (self.payloads[self.history_payloads.end..]) |payload| {
            try encodePayload(destination, self.key, payload);
        }
    }

    /// Encode the KITTY_IMAGE_PAGE_PLACEMENTS record for one history page, if
    /// any placement is pinned to it, and nothing otherwise. Then encode the
    /// KITTY_IMAGE_PAYLOAD records of the images that are first placed on
    /// this page, so they arrive with the text around them. Call this right
    /// after the page's PAGE record. Pages must be visited newest first, in
    /// the same order HISTORY encodes them.
    pub fn encodePagePlacements(
        self: *ScreenPlan,
        node: *const Node,
        destination: *record.Writer,
    ) EncodeError!void {
        const start = self.history_next;
        var end = start;
        while (end < self.history.len and
            self.history[end].root.?.node == node) end += 1;
        if (end > start) {
            self.history_next = end;

            const writer = destination.begin(.kitty_image_page_placements);
            errdefer destination.cancel();
            try encodeKey(writer, self.key);
            try io.writeInt(writer, u32, @intCast(end - start));
            for (self.history[start..end]) |planned| {
                try encodePlacement(writer, planned, .page);
            }
            try destination.finish();
        }

        while (self.payload_next < self.history_payloads.end and
            self.payloads[self.payload_next].node == node) : (self.payload_next += 1)
        {
            try encodePayload(destination, self.key, self.payloads[self.payload_next]);
        }
    }
};

fn encodeImage(writer: *std.Io.Writer, img: *const Image) !void {
    try io.writeInt(writer, u32, img.id);
    try io.writeInt(writer, u32, img.number);
    try io.writeInt(writer, u32, img.width);
    try io.writeInt(writer, u32, img.height);
    try writer.writeByte(encodeFormat(img.format));
    try writer.writeByte(@bitCast(imageFlags(img)));
    try io.writeInt(writer, u64, img.data.len());

    const anim = img.animation orelse {
        try writer.writeByte(0);
        return;
    };
    try writer.writeByte(1);
    try writer.writeByte(switch (anim.state) {
        .stopped => 0,
        .loading => 1,
        .running => 2,
    });
    try io.writeInt(writer, u32, anim.max_loops);
    try io.writeInt(writer, u32, anim.current_loop);
    try io.writeInt(writer, u32, anim.current_index);
    try io.writeInt(writer, u32, anim.root_gap_ms);
    try io.writeInt(writer, u32, @intCast(anim.frames.items.len));
    for (anim.frames.items) |frame| {
        try io.writeInt(writer, u32, frame.gap_ms);
        try io.writeInt(writer, u64, frame.storageSize());
    }
}

/// Which record a placement is written to, which decides how its pin is
/// written.
const PinContext = union(enum) {
    /// KITTY_IMAGE_STORAGE. The pin names its page by position in the SCREEN
    /// sequence. The value is `ScreenPlan.first_resident`, which is
    /// subtracted from the page's position in the full page list.
    storage: u32,

    /// KITTY_IMAGE_PAGE_PLACEMENTS. The pin is always on the history page right
    /// before the record, so only the row and column are written.
    page,
};

fn encodePlacementKey(writer: *std.Io.Writer, key: PlacementKey) !void {
    try io.writeInt(writer, u32, key.image_id);
    try writer.writeByte(@backingInt(key.placement_id.tag));
    try io.writeInt(writer, u32, key.placement_id.id);
}

fn encodePlacement(
    writer: *std.Io.Writer,
    planned: PlannedPlacement,
    context: PinContext,
) !void {
    const p = planned.placement;
    try encodePlacementKey(writer, planned.key);
    switch (p.location) {
        .pin => |pin| {
            try writer.writeByte(0);
            switch (context) {
                .storage => |first| try io.writeInt(
                    writer,
                    u16,
                    @intCast(planned.root.?.ordinal - first),
                ),
                .page => {},
            }
            try io.writeInt(writer, u16, pin.y);
            try io.writeInt(writer, u16, pin.x);
        },
        .virtual => try writer.writeByte(1),
        .relative => |rel| {
            try writer.writeByte(2);
            try encodePlacementKey(writer, rel.parent);
            try io.writeInt(writer, i32, rel.horizontal_offset);
            try io.writeInt(writer, i32, rel.vertical_offset);
        },
    }
    try io.writeInt(writer, u32, p.x_offset);
    try io.writeInt(writer, u32, p.y_offset);
    try io.writeInt(writer, u32, p.source_x);
    try io.writeInt(writer, u32, p.source_y);
    try io.writeInt(writer, u32, p.source_width);
    try io.writeInt(writer, u32, p.source_height);
    try io.writeInt(writer, u32, p.columns);
    try io.writeInt(writer, u32, p.rows);
    try io.writeInt(writer, i32, p.z);
}

fn encodeLoading(writer: *std.Io.Writer, loading: *const LoadingImage) !void {
    const img = &loading.image;
    try io.writeInt(writer, u32, img.id);
    try io.writeInt(writer, u32, img.number);
    try io.writeInt(writer, u32, img.width);
    try io.writeInt(writer, u32, img.height);
    try writer.writeByte(encodeFormat(img.format));
    try writer.writeByte(encodeCompression(img.compression));
    try writer.writeByte(@bitCast(imageFlags(img)));
    try writer.writeByte(switch (loading.quiet) {
        .no => 0,
        .ok => 1,
        .failures => 2,
    });
    try io.writeInt(writer, u32, loading.response.id);
    try io.writeInt(writer, u32, loading.response.image_number);
    try io.writeInt(writer, u32, loading.response.placement_id);
    try io.writeInt(writer, u32, loading.response.frame);

    if (loading.display) |d| {
        try writer.writeByte(1);
        inline for (.{
            d.image_id, d.image_number, d.placement_id,
            d.x,        d.y,            d.width,
            d.height,   d.x_offset,     d.y_offset,
            d.columns,  d.rows,
        }) |value| try io.writeInt(writer, u32, value);
        try writer.writeByte(switch (d.cursor_movement) {
            .after => 0,
            .none => 1,
        });
        try writer.writeByte(@intFromBool(d.virtual_placement));
        try io.writeInt(writer, u32, d.parent_id);
        try io.writeInt(writer, u32, d.parent_placement_id);
        try io.writeInt(writer, i32, d.horizontal_offset);
        try io.writeInt(writer, i32, d.vertical_offset);
        try io.writeInt(writer, i32, d.z);
    } else try writer.writeByte(0);

    if (loading.frame) |frame| {
        const f = frame.cmd;
        const t = f.transmission;
        try writer.writeByte(1);
        try writer.writeByte(encodeFormat(t.format));
        try writer.writeByte(switch (t.medium) {
            .direct => 0,
            .file => 1,
            .temporary_file => 2,
            .shared_memory => 3,
        });
        inline for (.{
            t.width,        t.height,   t.size,
            t.offset,       t.image_id, t.image_number,
            t.placement_id,
        }) |value| try io.writeInt(writer, u32, value);
        try writer.writeByte(encodeCompression(t.compression));
        try writer.writeByte(@intFromBool(t.more_chunks));
        try io.writeInt(writer, u32, @bitCast(t.usage));
        try io.writeInt(writer, u32, f.x);
        try io.writeInt(writer, u32, f.y);
        try io.writeInt(writer, u32, f.create_frame);
        try io.writeInt(writer, u32, f.edit_frame);
        try io.writeInt(writer, i32, f.gap_ms);
        try writer.writeByte(switch (f.composition_mode) {
            .alpha_blend => 0,
            .overwrite => 1,
        });
        try io.writeInt(writer, u32, @bitCast(f.background));
    } else try writer.writeByte(0);

    try io.writeInt(writer, u32, @intCast(loading.data.items.len));
    try writer.writeAll(loading.data.items);
}

const Compression = graphics_command.Transmission.Compression;

fn encodeCompression(value: Compression) u8 {
    return switch (value) {
        .none => 0,
        .zlib_deflate => 1,
    };
}

fn decodeCompression(raw: u8) ?Compression {
    return switch (raw) {
        0 => .none,
        1 => .zlib_deflate,
        else => null,
    };
}

/// The number of KITTY_IMAGE_PAYLOAD bytes before the pixel bytes.
const payload_header_len = 18;

/// Encode one KITTY_IMAGE_PAYLOAD record.
fn encodePayload(
    destination: *record.Writer,
    key: TerminalScreenKey,
    payload: PlannedPayload,
) EncodeError!void {
    const bytes = payload.bytes();
    const writer = destination.begin(.kitty_image_payload);
    errdefer destination.cancel();
    try encodeKey(writer, key);
    try io.writeInt(writer, u32, payload.image.id);
    try io.writeInt(writer, u32, payload.frame);
    try io.writeInt(writer, u64, bytes.len);
    assert(writer.end == payload_header_len);
    try writer.writeAll(bytes);
    try destination.finish();
}

// ---------------------------------------------------------------------------
// Decoding

/// The Kitty graphics a screen had when the snapshot reached READY. See
/// `snapshot.Decoded.kitty` for how to show progress with it.
pub const Counts = struct {
    /// Images restored into the screen's storage.
    images: u32 = 0,

    /// Bytes of image and frame pixels that have not arrived yet.
    pending_bytes: u64 = 0,

    /// Count the images in `storage` and the bytes of their pixels that
    /// are still pending.
    pub fn init(storage: *const ImageStorage) Counts {
        var result: Counts = .{};
        var it = storage.images.valueIterator();
        while (it.next()) |img| {
            result.images += 1;
            if (img.data.isPending()) result.pending_bytes += img.data.len();
            const anim = img.animation orelse continue;
            for (anim.frames.items) |frame| {
                if (frame.isPending()) result.pending_bytes += frame.pending_len;
            }
        }
        return result;
    }
};

/// Decode one KITTY_IMAGE_STORAGE record into `screen`.
///
/// `record_header` is the record's header, already read from `source`. A
/// header for any other kind of record returns `error.UnexpectedRecordTag`.
/// See "Decoding Records" in `record.zig`.
///
/// A KITTY_IMAGE_STORAGE record comes right after the SCREEN records of the
/// screen it belongs to. Pass that screen's `key` and the `screen` freshly
/// restored from those records, with no images yet. A record that names a
/// different screen returns `error.UnexpectedKittyKey`.
///
/// Images are restored with their pixels pending, oldest first, under the
/// screen's current storage limit. An image that does not fit evicts older
/// images, exactly as a live transmission would, so the newest images are
/// kept. Invalid images and placements, and placements whose image or
/// parent was dropped, are left out rather than failing the snapshot.
///
/// ```zig
/// // Right after restoring the primary screen from its SCREEN records:
/// const header = try record.nextHeader(source);
/// if (header.tag == .kitty_image_storage) {
///     try kitty.decodeStorage(source, header, io, alloc, .primary, primary);
/// }
/// ```
pub fn decodeStorage(
    source: *std.Io.Reader,
    record_header: record.Header,
    io_: std.Io,
    alloc: Allocator,
    key: TerminalScreenKey,
    screen: *TerminalScreen,
) DecodeError!void {
    var record_reader: record.Reader = undefined;
    record_reader.initHeader(source, record_header);
    if (record_header.tag != .kitty_image_storage) return error.UnexpectedRecordTag;

    const reader = record_reader.payloadReader();
    if (try decodeKey(reader) != key) return error.UnexpectedKittyKey;
    const storage = &screen.kitty_images;

    const next_image_id = try io.readInt(reader, u32);
    const next_internal_placement_id = try io.readInt(reader, u32);
    const image_count = try io.readInt(reader, u32);
    const placement_count = try io.readInt(reader, u32);
    const loading_present = try reader.takeByte();

    for (0..image_count) |_| {
        var decoded = try DecodedImage.decode(reader, alloc);
        defer decoded.deinit(alloc);
        try decoded.restore(io_, alloc, screen);
    }

    // Pin locations index the restored SCREEN pages.
    var nodes: std.ArrayList(*Node) = .empty;
    defer nodes.deinit(alloc);
    {
        var node = screen.pages.pages.first;
        while (node) |current| : (node = current.next) {
            try nodes.append(alloc, current);
        }
    }
    for (0..placement_count) |_| {
        const decoded = try DecodedPlacement.decode(reader, .storage);
        try decoded.restore(
            io_,
            alloc,
            screen,
            .{ .storage = nodes.items },
            null,
        );
    }

    if (loading_present != 0) try decodeLoading(
        reader,
        record_reader.header.payload_len,
        alloc,
        storage,
    );
    try record_reader.finish();

    storage.next_image_id = next_image_id;
    storage.next_internal_placement_id = next_internal_placement_id;
}

/// One decoded image entry.
const DecodedImage = struct {
    image: Image,

    /// The decoded animation with every frame pending, owned until
    /// `restore` moves it into storage.
    animation: ?*Animation,

    /// False when the entry cannot describe a stored image.
    valid: bool,

    fn decode(
        reader: *std.Io.Reader,
        alloc: Allocator,
    ) DecodeError!DecodedImage {
        const id = try io.readInt(reader, u32);
        const number = try io.readInt(reader, u32);
        const width = try io.readInt(reader, u32);
        const height = try io.readInt(reader, u32);
        const format = decodeFormat(try reader.takeByte());
        const flags: ImageFlags = @bitCast(try reader.takeByte());
        const data_len = try io.readInt(reader, u64);

        var valid = valid: {
            if (id == 0) break :valid false;
            const f = format orelse break :valid false;
            const expected = imageLen(width, height, f) orelse
                break :valid false;
            break :valid expected == data_len;
        };

        var result: DecodedImage = .{
            .image = .{
                .id = id,
                .number = number,
                .width = width,
                .height = height,
                .format = format orelse .rgba,
                .data = .{ .pending = if (valid) @intCast(data_len) else 0 },
                .metadata = .{
                    .transient = flags.transient,
                    .implicit_id = flags.implicit_id,
                },
            },
            .animation = null,
            .valid = valid,
        };
        errdefer result.deinit(alloc);

        if (try reader.takeByte() == 0) return result;
        const state: Animation.State = switch (try reader.takeByte()) {
            1 => .loading,
            2 => .running,
            else => .stopped,
        };
        const max_loops = try io.readInt(reader, u32);
        const current_loop = try io.readInt(reader, u32);
        const current_index = try io.readInt(reader, u32);
        const root_gap_ms = try io.readInt(reader, u32);
        const frame_count = try io.readInt(reader, u32);

        const anim = try alloc.create(Animation);
        anim.* = .{
            .state = state,
            .max_loops = max_loops,
            .current_loop = current_loop,
            .root_gap_ms = root_gap_ms,
        };
        result.animation = anim;

        // Frames are always full-size RGBA. Every frame entry is read even
        // for an invalid image so the payload stays aligned.
        const frame_len: ?usize = std.math.mul(
            usize,
            @as(usize, width) * height,
            4,
        ) catch null;
        for (0..frame_count) |_| {
            const gap_ms = try io.readInt(reader, u32);
            const len = try io.readInt(reader, u64);
            if (!valid) continue;
            if (frame_len == null or frame_len.? == 0 or len != frame_len.?) {
                valid = false;
                continue;
            }
            try anim.frames.append(alloc, .{
                .data = &.{},
                .gap_ms = gap_ms,
                .pending_len = frame_len.?,
            });
        }
        anim.current_index = if (current_index <= anim.frames.items.len)
            current_index
        else
            0;
        result.valid = valid;
        return result;
    }

    fn deinit(self: *DecodedImage, alloc: Allocator) void {
        if (self.animation) |anim| {
            anim.deinit(alloc);
            alloc.destroy(anim);
        }
        self.* = undefined;
    }

    /// Add the image to storage as a pending image, unless it is invalid
    /// or larger than the whole storage limit.
    fn restore(
        self: *DecodedImage,
        io_: std.Io,
        alloc: Allocator,
        screen: *TerminalScreen,
    ) DecodeError!void {
        if (!self.valid) return;
        const storage = &screen.kitty_images;

        // An image that cannot fit even in an empty storage is dropped
        // rather than evicting everything else for nothing.
        const base_len = self.image.data.len();
        const frame_bytes = if (self.animation) |a| a.frameBytes() else 0;
        if (base_len + frame_bytes > storage.total_limit) return;

        _ = try storage.addPendingImage(io_, alloc, screen, self.image);
        const anim = self.animation orelse return;
        if (frame_bytes > 0) {
            // Older images could not make room. Keep the image itself and
            // drop its animation.
            storage.reserveAnimationBytes(
                io_,
                alloc,
                screen,
                self.image.id,
                frame_bytes,
            ) catch return;
        }
        storage.images.getPtr(self.image.id).?.animation = anim;
        self.animation = null;
    }
};

/// Where pinned placements are located while decoding.
const PinTarget = union(enum) {
    /// KITTY_IMAGE_STORAGE: the restored screen's pages in SCREEN order.
    storage: []const *Node,

    /// KITTY_IMAGE_PAGE_PLACEMENTS: the history page that was just prepended.
    page: *Node,
};

/// One decoded placement entry.
const DecodedPlacement = struct {
    key: ?PlacementKey,
    location: Location,
    placement: Placement,

    const Location = union(enum) {
        pin: struct { page: u16, y: u16, x: u16 },
        virtual,
        relative: Placement.Relative,

        /// Not a location the placement's record may carry.
        invalid,
    };

    fn decodePlacementKey(reader: *std.Io.Reader) DecodeError!?PlacementKey {
        const image_id = try io.readInt(reader, u32);
        const tag_raw = try reader.takeByte();
        const id = try io.readInt(reader, u32);
        const tag: @FieldType(PlacementId, "tag") = switch (tag_raw) {
            0 => .internal,
            1 => .external,
            else => return null,
        };
        // An explicit placement ID of zero means "assign one internally".
        if (tag == .external and id == 0) return null;
        return .{
            .image_id = image_id,
            .placement_id = .{ .tag = tag, .id = id },
        };
    }

    fn decode(
        reader: *std.Io.Reader,
        context: std.meta.Tag(PinContext),
    ) DecodeError!DecodedPlacement {
        const key = try decodePlacementKey(reader);
        const location: Location = switch (try reader.takeByte()) {
            0 => .{ .pin = .{
                .page = switch (context) {
                    .storage => try io.readInt(reader, u16),
                    .page => 0,
                },
                .y = try io.readInt(reader, u16),
                .x = try io.readInt(reader, u16),
            } },
            1 => switch (context) {
                .storage => .virtual,
                .page => .invalid,
            },
            2 => relative: {
                const parent = try decodePlacementKey(reader);
                const horizontal = try io.readInt(reader, i32);
                const vertical = try io.readInt(reader, i32);
                break :relative if (parent) |p| .{ .relative = .{
                    .parent = p,
                    .horizontal_offset = horizontal,
                    .vertical_offset = vertical,
                } } else .invalid;
            },
            else => .invalid,
        };

        return .{
            .key = key,
            .location = location,
            .placement = .{
                .location = .virtual,
                .x_offset = try io.readInt(reader, u32),
                .y_offset = try io.readInt(reader, u32),
                .source_x = try io.readInt(reader, u32),
                .source_y = try io.readInt(reader, u32),
                .source_width = try io.readInt(reader, u32),
                .source_height = try io.readInt(reader, u32),
                .columns = try io.readInt(reader, u32),
                .rows = try io.readInt(reader, u32),
                .z = try io.readInt(reader, i32),
            },
        };
    }

    /// Insert the placement with its exact key. It is left out if its key
    /// or location is invalid, its image or parent is missing, or the key
    /// is already in use. With a `ready_generation` (see `PageTarget`), the
    /// image must also be one the snapshot restored, not one that live
    /// input sent since.
    fn restore(
        self: DecodedPlacement,
        io_: std.Io,
        alloc: Allocator,
        screen: *TerminalScreen,
        pins: PinTarget,
        ready_generation: ?u64,
    ) DecodeError!void {
        const storage = &screen.kitty_images;
        const key = self.key orelse return;
        const img = storage.images.getPtr(key.image_id) orelse return;
        if (ready_generation) |ready| if (img.transmission > ready) return;
        if (storage.placements.contains(key)) return;

        var placement = self.placement;
        switch (self.location) {
            .invalid => return,
            .virtual => placement.location = .virtual,
            .relative => |rel| {
                // Parents always precede their children.
                if (!storage.placements.contains(rel.parent)) return;
                placement.location = .{ .relative = rel };
            },
            .pin => |pin| {
                const node = switch (pins) {
                    .storage => |nodes| if (pin.page < nodes.len)
                        nodes[pin.page]
                    else
                        return,
                    .page => |node| node,
                };
                if (pin.y >= node.rows() or pin.x >= node.cols()) return;
                placement.location = .{ .pin = try screen.pages.trackPin(.{
                    .node = node,
                    .y = pin.y,
                    .x = pin.x,
                }) };
            },
        }
        errdefer placement.deinit(screen);

        const count = std.math.add(
            @TypeOf(img.metadata.placement_count),
            img.metadata.placement_count,
            1,
        ) catch {
            placement.deinit(screen);
            return;
        };
        try storage.placements.putNoClobber(alloc, key, placement);
        img.metadata.placement_count = count;
        storage.markMutated(io_);
    }
};

/// Decode the in-progress load and install it, unless the storage cannot
/// accept transmissions or the load is invalid.
fn decodeLoading(
    reader: *std.Io.Reader,
    payload_len: u32,
    alloc: Allocator,
    storage: *ImageStorage,
) DecodeError!void {
    const id = try io.readInt(reader, u32);
    const number = try io.readInt(reader, u32);
    const width = try io.readInt(reader, u32);
    const height = try io.readInt(reader, u32);
    const format = decodeFormat(try reader.takeByte());
    const compression = decodeCompression(try reader.takeByte());
    const flags: ImageFlags = @bitCast(try reader.takeByte());
    const quiet: ?graphics.Command.Quiet = switch (try reader.takeByte()) {
        0 => .no,
        1 => .ok,
        2 => .failures,
        else => null,
    };
    const response: graphics.Response = .{
        .id = try io.readInt(reader, u32),
        .image_number = try io.readInt(reader, u32),
        .placement_id = try io.readInt(reader, u32),
        .frame = try io.readInt(reader, u32),
    };

    var valid = format != null and compression != null and quiet != null;

    const display: ?graphics_command.Display = switch (try reader.takeByte()) {
        0 => null,
        else => display: {
            var d: graphics_command.Display = .{};
            inline for (.{
                "image_id", "image_number", "placement_id",
                "x",        "y",            "width",
                "height",   "x_offset",     "y_offset",
                "columns",  "rows",
            }) |field| @field(d, field) = try io.readInt(reader, u32);
            d.cursor_movement = switch (try reader.takeByte()) {
                0 => .after,
                1 => .none,
                else => invalid: {
                    valid = false;
                    break :invalid .after;
                },
            };
            d.virtual_placement = try reader.takeByte() != 0;
            d.parent_id = try io.readInt(reader, u32);
            d.parent_placement_id = try io.readInt(reader, u32);
            d.horizontal_offset = try io.readInt(reader, i32);
            d.vertical_offset = try io.readInt(reader, i32);
            d.z = try io.readInt(reader, i32);
            break :display d;
        },
    };

    const frame: ?graphics_command.AnimationFrameLoading = switch (try reader.takeByte()) {
        0 => null,
        else => frame: {
            var f: graphics_command.AnimationFrameLoading = .{};
            const t = &f.transmission;
            t.format = decodeFormat(try reader.takeByte()) orelse invalid: {
                valid = false;
                break :invalid .rgba;
            };
            t.medium = switch (try reader.takeByte()) {
                0 => .direct,
                1 => .file,
                2 => .temporary_file,
                3 => .shared_memory,
                else => invalid: {
                    valid = false;
                    break :invalid .direct;
                },
            };
            inline for (.{
                "width",        "height",   "size",
                "offset",       "image_id", "image_number",
                "placement_id",
            }) |field| @field(t, field) = try io.readInt(reader, u32);
            t.compression = decodeCompression(try reader.takeByte()) orelse invalid: {
                valid = false;
                break :invalid .none;
            };
            t.more_chunks = try reader.takeByte() != 0;
            t.usage = @bitCast(try io.readInt(reader, u32));
            f.x = try io.readInt(reader, u32);
            f.y = try io.readInt(reader, u32);
            f.create_frame = try io.readInt(reader, u32);
            f.edit_frame = try io.readInt(reader, u32);
            f.gap_ms = try io.readInt(reader, i32);
            f.composition_mode = switch (try reader.takeByte()) {
                0 => .alpha_blend,
                1 => .overwrite,
                else => invalid: {
                    valid = false;
                    break :invalid .alpha_blend;
                },
            };
            f.background = @bitCast(try io.readInt(reader, u32));
            break :frame f;
        },
    };

    // The received bytes are bounded by the record itself, so a corrupt
    // length cannot force a large allocation.
    const data_len = try io.readInt(reader, u32);
    if (data_len > payload_len) return error.EndOfStream;
    const data = try alloc.alloc(u8, data_len);
    defer alloc.free(data);
    try reader.readSliceAll(data);

    if (!valid or !storage.enabled()) return;

    var loading: LoadingImage = .{
        .image = .{
            .id = id,
            .number = number,
            .width = width,
            .height = height,
            .format = format.?,
            .compression = compression.?,
            .metadata = .{
                .transient = flags.transient,
                .implicit_id = flags.implicit_id,
            },
        },
        .display = display,
        .quiet = quiet.?,
        .response = response,
        .temporary_directory = switch (storage.image_limits.temporary_file) {
            .enabled => |d| d.directory,
            .disabled => null,
        },
    };
    errdefer loading.deinit(alloc);

    // A frame load completes only against the image it started on, which
    // is identified by its generation. Stamps are process-local, so use
    // the restored image's fresh one.
    if (frame) |f| loading.frame = .{
        .cmd = f,
        .image_generation = if (storage.imagePtrByIdOrNumber(id, number)) |img|
            img.generation
        else
            0,
    };

    // addData enforces the same size bound as live loading.
    loading.addData(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidData => {
            loading.deinit(alloc);
            return;
        },
    };

    const result = try alloc.create(LoadingImage);
    result.* = loading;
    storage.loading = result;
}

/// A screen that KITTY_IMAGE_PAYLOAD records may complete images on. See
/// `decodePayload`.
pub const PayloadTarget = struct {
    /// The screen restored at READY.
    screen: *TerminalScreen,

    /// The screen's image storage `generation` at READY. An image whose
    /// `transmission` is newer than this was sent by live input after
    /// READY, and only shares an ID with the snapshot's image. See
    /// `PageTarget.ready_generation`.
    ready_generation: u64,
};

/// The screens that KITTY_IMAGE_PAYLOAD records may complete images on, by
/// screen key. See `decodePayload`.
pub const PayloadTargets = std.EnumMap(TerminalScreenKey, PayloadTarget);

/// What one KITTY_IMAGE_PAYLOAD record held.
pub const Payload = struct {
    /// The screen the record names.
    key: TerminalScreenKey,

    /// The image the pixels are for.
    image_id: u32,

    /// The frame number, as the Kitty graphics protocol counts frames. 1 is
    /// the image itself and 2 and up are its animation frames.
    frame: u32,

    /// The number of pixel bytes attached to the image, or zero when the
    /// payload was dropped.
    bytes: usize,
};

/// Decode one KITTY_IMAGE_PAYLOAD record and attach its pixels to the pending
/// image or animation frame they belong to.
///
/// `record_header` is the record's header, already read from `source`. A
/// header for any other kind of record returns `error.UnexpectedRecordTag`.
/// See "Decoding Records" in `record.zig`.
///
/// The record names its own screen, and `targets` gives the screen to use
/// for each key. Leave out a screen that is gone, because live input
/// removed it or replaced it with a new one since READY. The result
/// reports the record's screen in `key`, so the caller can check that the
/// snapshot declared it.
///
/// The pixels are attached only if `targets` has the record's screen, that
/// screen still has the image the snapshot restored, and the image or
/// frame is still pending with the same length. Otherwise the record is
/// read and checked but its pixels are dropped, and the result reports
/// zero bytes.
///
/// ```zig
/// var targets: kitty.PayloadTargets = .init(.{});
/// targets.put(.primary, .{
///     .screen = primary,
///     .ready_generation = primary_generation_at_ready,
/// });
///
/// const header = try record.nextHeader(source);
/// if (header.tag == .kitty_image_payload) {
///     const payload = try kitty.decodePayload(source, header, io, alloc, targets);
///     if (payload.key != .primary) return error.UnexpectedKittyKey;
/// }
/// ```
pub fn decodePayload(
    source: *std.Io.Reader,
    record_header: record.Header,
    io_: std.Io,
    alloc: Allocator,
    targets: PayloadTargets,
) DecodeError!Payload {
    var record_reader: record.Reader = undefined;
    record_reader.initHeader(source, record_header);
    if (record_header.tag != .kitty_image_payload) return error.UnexpectedRecordTag;

    const reader = record_reader.payloadReader();
    const key = try decodeKey(reader);
    const image_id = try io.readInt(reader, u32);
    const frame = try io.readInt(reader, u32);
    const decoded_len = try io.readInt(reader, u64);
    const target = targets.get(key);

    var result: Payload = .{
        .key = key,
        .image_id = image_id,
        .frame = frame,
        .bytes = 0,
    };

    // Find the pending image or frame these pixels complete, and the
    // ticket to complete it with.
    const ticket: ?ImageStorage.PendingImage = ticket: {
        const t = target orelse break :ticket null;
        const img = t.screen.kitty_images.images.getPtr(image_id) orelse
            break :ticket null;
        if (img.transmission > t.ready_generation) break :ticket null;
        const expected: usize = switch (frame) {
            0 => break :ticket null,
            1 => switch (img.data) {
                .pending => |len| len,
                .complete => break :ticket null,
            },
            else => expected: {
                const anim = img.animation orelse break :ticket null;
                if (frame - 2 >= anim.frames.items.len) break :ticket null;
                const pending = anim.frames.items[frame - 2];
                if (!pending.isPending()) break :ticket null;
                break :expected pending.pending_len;
            },
        };
        if (expected != decoded_len) break :ticket null;
        break :ticket .{ .id = image_id, .transmission = img.transmission };
    };
    const pending = ticket orelse {
        _ = try reader.discardRemaining();
        try record_reader.finish();
        return result;
    };

    // The record must hold exactly the declared pixels: a short one fails
    // the read, a long one fails `finish`.
    const data = try alloc.alloc(u8, @intCast(decoded_len));
    var owned = true;
    defer if (owned) alloc.free(data);
    try reader.readSliceAll(data);
    try record_reader.finish();

    const storage = &target.?.screen.kitty_images;
    const attached = switch (frame) {
        1 => pending.complete(storage, io_, data),
        else => pending.completeFrame(storage, io_, frame, data),
    };
    if (attached) {
        owned = false;
        result.bytes = data.len;
    }
    return result;
}

/// The history page a KITTY_IMAGE_PAGE_PLACEMENTS record restores placements
/// onto. See `decodePagePlacements`.
pub const PageTarget = struct {
    /// The screen the page belongs to.
    screen: *TerminalScreen,

    /// The history page that was just added to `screen`, which the
    /// record's pins refer to.
    page: *Node,

    /// The screen's image storage `generation` when the snapshot reached
    /// READY. Generations only grow, so an image whose `transmission` is
    /// newer than this was sent by live input after READY. Such an image
    /// merely shares an ID with the one the snapshot placed, so it gets no
    /// placements from the snapshot.
    ready_generation: u64,
};

/// Decode one KITTY_IMAGE_PAGE_PLACEMENTS record, which holds the placements
/// pinned to the history page right before it.
///
/// `record_header` is the record's header, already read from `source`. A
/// header for any other kind of record returns `error.UnexpectedRecordTag`.
/// See "Decoding Records" in `record.zig`. The record must belong to the
/// screen `key`, which owns the HISTORY sequence it appears in, or this
/// returns `error.UnexpectedKittyKey`.
///
/// With a `target`, the placements are restored onto that page. Pass null
/// when the page itself was dropped, for example because the terminal was
/// resized since READY. The record is then read and checked, and its
/// placements are dropped along with their page.
///
/// ```zig
/// // Right after restoring a history page onto the top of `screen`:
/// const header = try record.nextHeader(source);
/// if (header.tag == .kitty_image_page_placements) {
///     try kitty.decodePagePlacements(source, header, io, alloc, .primary, .{
///         .screen = screen,
///         .page = screen.pages.pages.first.?,
///         .ready_generation = generation_at_ready,
///     });
/// }
/// ```
pub fn decodePagePlacements(
    source: *std.Io.Reader,
    record_header: record.Header,
    io_: std.Io,
    alloc: Allocator,
    key: TerminalScreenKey,
    target: ?PageTarget,
) DecodeError!void {
    var record_reader: record.Reader = undefined;
    record_reader.initHeader(source, record_header);
    if (record_header.tag != .kitty_image_page_placements) {
        return error.UnexpectedRecordTag;
    }

    const reader = record_reader.payloadReader();
    if (try decodeKey(reader) != key) return error.UnexpectedKittyKey;
    const count = try io.readInt(reader, u32);
    for (0..count) |_| {
        const decoded = try DecodedPlacement.decode(reader, .page);
        const t = target orelse continue;
        try decoded.restore(
            io_,
            alloc,
            t.screen,
            .{ .page = t.page },
            t.ready_generation,
        );
    }
    try record_reader.finish();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const test_fixture = @import("fixture.zig");
const snapshot = @import("snapshot.zig");
const Terminal = @import("../Terminal.zig");
const RenderState = @import("../render.zig").RenderState;

/// A small terminal with pixel geometry, so placement sizes are nonzero.
fn testTerminal(cols: u16, rows: u16) !Terminal {
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    t.width_px = @as(u32, cols) * 10;
    t.height_px = @as(u32, rows) * 20;
    return t;
}

/// Feed VT bytes to a terminal.
fn testFeed(t: *Terminal, bytes: []const u8) void {
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
}

/// Feed one Kitty graphics command with a base64 encoded payload.
fn testCommand(t: *Terminal, keys: []const u8, payload: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded = try testing.allocator.alloc(u8, encoder.calcSize(payload.len));
    defer testing.allocator.free(encoded);
    _ = encoder.encode(encoded, payload);
    const command = try std.mem.concat(testing.allocator, u8, &.{
        "\x1b_G",
        keys,
        if (payload.len > 0) ";" else "",
        encoded,
        "\x1b\\",
    });
    defer testing.allocator.free(command);
    testFeed(t, command);
}

/// RGBA pixels of one repeated color.
fn testPixels(comptime len: usize, rgba: [4]u8) [len]u8 {
    var result: [len]u8 = undefined;
    for (0..len / 4) |i| result[i * 4 ..][0..4].* = rgba;
    return result;
}

fn testEncode(t: *const Terminal) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer encoded.deinit();
    try snapshot.encode(testing.allocator, &encoded.writer, t, .{
        .continuation = .ground,
    });
    return encoded.toOwnedSlice();
}

/// Decode a complete snapshot through a one-byte reader buffer, so every
/// record is read in the smallest possible pieces.
fn testDecode(bytes: []const u8, options: snapshot.DecodeOptions) !Terminal {
    var source: std.Io.Reader = .fixed(bytes);
    var buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buf);
    var decoded = try snapshot.decode(
        testing.allocator,
        testing.io,
        &limited.interface,
        options,
    );
    defer decoded.deinit(testing.allocator);
    return decoded.toOwned();
}

const test_decode_options: snapshot.DecodeOptions = .{
    .max_continuation_bytes = 1024,
};

/// Require two screens' Kitty graphics storage to hold the same images,
/// pixels, placements and in-progress load, with the same render geometry.
fn expectStorageEqual(
    expected_terminal: *const Terminal,
    actual_terminal: *const Terminal,
    key: TerminalScreenKey,
) !void {
    const expected_screen = expected_terminal.screens.get(key).?;
    const actual_screen = actual_terminal.screens.get(key).?;
    const expected = &expected_screen.kitty_images;
    const actual = &actual_screen.kitty_images;

    try testing.expectEqual(expected.next_image_id, actual.next_image_id);
    try testing.expectEqual(
        expected.next_internal_placement_id,
        actual.next_internal_placement_id,
    );
    try testing.expectEqual(expected.total_bytes, actual.total_bytes);

    try testing.expectEqual(expected.images.count(), actual.images.count());
    var image_it = expected.images.valueIterator();
    while (image_it.next()) |e| {
        const a = actual.images.getPtr(e.id).?;
        try testing.expectEqual(e.number, a.number);
        try testing.expectEqual(e.width, a.width);
        try testing.expectEqual(e.height, a.height);
        try testing.expectEqual(e.format, a.format);
        try testing.expectEqual(e.metadata, a.metadata);
        try testing.expectEqual(e.data.len(), a.data.len());
        try testing.expectEqual(e.data.isPending(), a.data.isPending());
        if (e.data.bytes()) |bytes| {
            try testing.expectEqualSlices(u8, bytes, a.data.bytes().?);
        }

        try testing.expectEqual(e.animation == null, a.animation == null);
        const e_anim = e.animation orelse continue;
        const a_anim = a.animation.?;
        try testing.expectEqual(e_anim.state, a_anim.state);
        try testing.expectEqual(e_anim.max_loops, a_anim.max_loops);
        try testing.expectEqual(e_anim.current_loop, a_anim.current_loop);
        try testing.expectEqual(e_anim.current_index, a_anim.current_index);
        try testing.expectEqual(e_anim.root_gap_ms, a_anim.root_gap_ms);
        try testing.expectEqual(e_anim.frames.items.len, a_anim.frames.items.len);
        for (e_anim.frames.items, a_anim.frames.items) |ef, af| {
            try testing.expectEqual(ef.gap_ms, af.gap_ms);
            try testing.expectEqual(ef.pending_len, af.pending_len);
            try testing.expectEqualSlices(u8, ef.data, af.data);
        }
    }

    try testing.expectEqual(expected.placements.count(), actual.placements.count());
    var placement_it = expected.placements.iterator();
    while (placement_it.next()) |entry| {
        const e = entry.value_ptr;
        const a = actual.placements.getPtr(entry.key_ptr.*).?;
        try testing.expectEqual(
            std.meta.activeTag(e.location),
            std.meta.activeTag(a.location),
        );
        switch (e.location) {
            .pin => |pin| try testing.expectEqual(
                expected_screen.pages.pointFromPin(.screen, pin.*).?,
                actual_screen.pages.pointFromPin(.screen, a.location.pin.*).?,
            ),
            .virtual => {},
            .relative => |rel| try testing.expectEqualDeep(
                rel,
                a.location.relative,
            ),
        }
        try testing.expectEqual(e.x_offset, a.x_offset);
        try testing.expectEqual(e.y_offset, a.y_offset);
        try testing.expectEqual(e.source_x, a.source_x);
        try testing.expectEqual(e.source_y, a.source_y);
        try testing.expectEqual(e.source_width, a.source_width);
        try testing.expectEqual(e.source_height, a.source_height);
        try testing.expectEqual(e.columns, a.columns);
        try testing.expectEqual(e.rows, a.rows);
        try testing.expectEqual(e.z, a.z);

        // The geometry placement_render_info reports.
        const img = expected.images.get(entry.key_ptr.image_id).?;
        const a_img = actual.images.get(entry.key_ptr.image_id).?;
        try testing.expectEqualDeep(
            e.pixelSize(img, expected_terminal),
            a.pixelSize(a_img, actual_terminal),
        );
        try testing.expectEqualDeep(
            e.gridSize(img, expected_terminal),
            a.gridSize(a_img, actual_terminal),
        );
        try testing.expectEqualDeep(e.sourceRect(img), a.sourceRect(a_img));
    }

    try testing.expectEqual(expected.loading == null, actual.loading == null);
    if (expected.loading) |e| {
        const a = actual.loading.?;
        try testing.expectEqual(e.image.id, a.image.id);
        try testing.expectEqual(e.image.number, a.image.number);
        try testing.expectEqual(e.image.width, a.image.width);
        try testing.expectEqual(e.image.height, a.image.height);
        try testing.expectEqual(e.image.format, a.image.format);
        try testing.expectEqual(e.image.compression, a.image.compression);
        try testing.expectEqual(e.image.metadata, a.image.metadata);
        try testing.expectEqualDeep(e.display, a.display);
        try testing.expectEqual(e.frame == null, a.frame == null);
        if (e.frame) |f| try testing.expectEqualDeep(f.cmd, a.frame.?.cmd);
        try testing.expectEqual(e.quiet, a.quiet);
        try testing.expectEqualDeep(e.response, a.response);
        try testing.expectEqualSlices(u8, e.data.items, a.data.items);
    }
}

/// Encode `t`, compare it with a golden fixture, decode the checked-in
/// fixture, and require the same storage contents and an identical
/// re-encoding.
fn testGolden(
    t: *const Terminal,
    comptime name: []const u8,
    fixture: []const u8,
) !void {
    const encoded = try testEncode(t);
    defer testing.allocator.free(encoded);
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/" ++ name ++ "-v1.hex",
        "snapshot_fixture-" ++ name ++ "-v1.hex",
        fixture,
        encoded,
    );

    var restored = try testDecode(fixture, test_decode_options);
    defer restored.deinit(testing.allocator);
    for (std.enums.values(TerminalScreenKey)) |key| {
        if (t.screens.get(key) == null) continue;
        try expectStorageEqual(t, &restored, key);
    }

    const reencoded = try testEncode(&restored);
    defer testing.allocator.free(reencoded);
    try testing.expectEqualSlices(u8, fixture, reencoded);
}

const test_placed_fixture = test_fixture.parse(@embedFile("testdata/kitty-placed-v1.hex"));

/// The terminal of the "placed" golden fixture.
fn testPlacedTerminal() !Terminal {
    var t = try testTerminal(4, 2);
    errdefer t.deinit(testing.allocator);

    // An 8x8 single-color image compresses well.
    const pixels = testPixels(256, .{ 255, 0, 0, 255 });
    try testCommand(&t, "a=T,f=32,s=8,v=8,i=1,c=2,r=1,C=1,q=2", &pixels);
    try testing.expectEqual(1, t.screens.active.kitty_images.placements.count());
    return t;
}

test "golden snapshot with one placed RGBA image" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testPlacedTerminal();
    defer t.deinit(testing.allocator);
    try testGolden(&t, "kitty-placed", &test_placed_fixture);
}

const test_source_rect_fixture = test_fixture.parse(@embedFile("testdata/kitty-source-rect-v1.hex"));

test "golden snapshot with a source rectangle and offsets" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testTerminal(4, 2);
    defer t.deinit(testing.allocator);

    const pixels = testPixels(64, .{ 0, 255, 0, 255 });
    try testCommand(
        &t,
        "a=T,f=32,s=4,v=4,i=2,p=7,x=1,y=1,w=2,h=2,X=3,Y=4,z=-5,C=1,q=2",
        &pixels,
    );
    try testGolden(&t, "kitty-source-rect", &test_source_rect_fixture);
}

const test_virtual_fixture = test_fixture.parse(@embedFile("testdata/kitty-virtual-v1.hex"));

/// The terminal of the "virtual" golden fixture: a 2x1 virtual placement
/// drawn by two placeholder cells.
fn testVirtualTerminal() !Terminal {
    var t = try testTerminal(4, 2);
    errdefer t.deinit(testing.allocator);

    const pixels = testPixels(16, .{ 0, 0, 255, 255 });
    try testCommand(&t, "a=T,U=1,f=32,s=2,v=2,i=3,c=2,r=1,q=2", &pixels);
    try t.setAttribute(.{ .@"256_fg" = 3 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}");
    return t;
}

test "golden snapshot with a virtual placement" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testVirtualTerminal();
    defer t.deinit(testing.allocator);
    try testGolden(&t, "kitty-virtual", &test_virtual_fixture);
}

const test_relative_fixture = test_fixture.parse(@embedFile("testdata/kitty-relative-v1.hex"));

test "golden snapshot with a relative chain rooted at a pinned placement" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testTerminal(4, 3);
    defer t.deinit(testing.allocator);

    const pixels = testPixels(4, .{ 1, 2, 3, 4 });
    try testCommand(&t, "a=t,f=32,s=1,v=1,i=1,q=2", &pixels);
    try testCommand(&t, "a=t,f=32,s=1,v=1,i=2,q=2", &pixels);

    // The root uses an internal placement ID, the children external ones.
    try testCommand(&t, "a=p,i=1,C=1,q=2", "");
    try testCommand(&t, "a=p,i=2,p=5,P=1,H=1,V=1,q=2", "");
    try testCommand(&t, "a=p,i=1,p=6,P=2,Q=5,H=-1,V=1,q=2", "");
    try testing.expectEqual(3, t.screens.active.kitty_images.placements.count());
    try testGolden(&t, "kitty-relative", &test_relative_fixture);
}

/// A 2x2 terminal whose primary screen has two complete two-row history
/// pages above the active page, using exact page capacities. The top-left
/// cells are 'A', 'B' and 'C' from the oldest page.
fn testHistoryTerminal() !Terminal {
    var t = try testTerminal(2, 2);
    errdefer t.deinit(testing.allocator);

    const primary = t.screens.get(.primary).?;
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{ .cols = 2, .rows = 2, .max_size = null, .max_lines = null },
        );
        defer builder.deinit();
        for ([_]u21{ 'A', 'B', 'C' }) |c| {
            const built = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
            built.size.rows = 2;
            built.getRowAndCell(0, 0).cell.* = .init(c);
        }
        var pages = try builder.finish();
        errdefer pages.deinit();
        const cursor_pin = try pages.trackPin(pages.pin(.{ .active = .{} }).?);
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    // Keep the storage limit policy of the original screen.
    replacement.kitty_images.total_limit = primary.kitty_images.total_limit;
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;
    return t;
}

/// Place image `image_id` at a cell of page `node` with a tracked pin.
fn testPlace(
    t: *Terminal,
    node: *Node,
    image_id: u32,
    placement_id: u32,
    y: u16,
    x: u16,
) !void {
    const screen = t.screens.active;
    const pin = try screen.pages.trackPin(.{ .node = node, .y = y, .x = x });
    try screen.kitty_images.addPlacement(
        testing.io,
        testing.allocator,
        screen,
        image_id,
        placement_id,
        .{ .location = .{ .pin = pin }, .columns = 1, .rows = 1 },
    );
}

const test_history_fixture = test_fixture.parse(@embedFile("testdata/kitty-history-v1.hex"));

/// The terminal of the "history" golden fixture: placements on both history
/// pages and on the active page, plus a relative child of a history
/// placement.
fn testHistoryPlacedTerminal() !Terminal {
    var t = try testHistoryTerminal();
    errdefer t.deinit(testing.allocator);

    const pixels = testPixels(4, .{ 9, 9, 9, 255 });
    try testCommand(&t, "a=t,f=32,s=1,v=1,i=4,q=2", &pixels);
    const oldest = t.screens.active.pages.pages.first.?;
    const newest_history = oldest.next.?;
    try testPlace(&t, oldest, 4, 1, 1, 1);
    try testPlace(&t, newest_history, 4, 2, 0, 0);
    try testPlace(&t, newest_history.next.?, 4, 3, 1, 0);
    try testCommand(&t, "a=p,i=4,p=9,P=4,Q=1,H=1,q=2", "");
    try testing.expectEqual(4, t.screens.active.kitty_images.placements.count());
    return t;
}

test "golden snapshot with placements in history" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testHistoryPlacedTerminal();
    defer t.deinit(testing.allocator);
    try testGolden(&t, "kitty-history", &test_history_fixture);
}

const test_animation_fixture = test_fixture.parse(@embedFile("testdata/kitty-animation-v1.hex"));

/// The terminal of the "animation" golden fixture.
fn testAnimationTerminal() !Terminal {
    var t = try testTerminal(4, 2);
    errdefer t.deinit(testing.allocator);

    try testCommand(&t, "a=T,f=32,s=2,v=1,i=5,C=1,q=2", &testPixels(8, .{ 255, 0, 0, 255 }));
    try testCommand(&t, "a=f,i=5,f=32,s=2,v=1,z=50,q=2", &testPixels(8, .{ 0, 255, 0, 255 }));
    try testCommand(&t, "a=f,i=5,f=32,s=1,v=1,z=70,q=2", &testPixels(4, .{ 0, 0, 255, 255 }));
    try testCommand(&t, "a=a,i=5,r=1,z=30,q=2", "");
    try testCommand(&t, "a=a,i=5,c=2,q=2", "");
    try testCommand(&t, "a=a,i=5,s=3,v=3,q=2", "");
    const anim = t.screens.active.kitty_images.imageById(5).?.animation.?;
    try testing.expectEqual(Animation.State.running, anim.state);
    try testing.expectEqual(3, anim.frameCount());
    try testing.expectEqual(1, anim.current_index);
    return t;
}

test "golden snapshot with a running three-frame animation" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testAnimationTerminal();
    defer t.deinit(testing.allocator);
    try testGolden(&t, "kitty-animation", &test_animation_fixture);
}

const test_loading_fixture = test_fixture.parse(@embedFile("testdata/kitty-loading-v1.hex"));

/// The pixels of the "loading" fixture's chunked transmission, of which
/// the first `test_loading_cut` bytes were sent.
const test_loading_pixels = testPixels(16, .{ 7, 7, 7, 255 });
const test_loading_cut = 6;

test "golden snapshot with an in-progress chunked load" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testTerminal(4, 2);
    defer t.deinit(testing.allocator);

    try testCommand(
        &t,
        "a=T,f=32,s=2,v=2,i=6,c=1,r=1,q=2,m=1",
        test_loading_pixels[0..test_loading_cut],
    );
    try testing.expect(t.screens.active.kitty_images.loading != null);
    try testGolden(&t, "kitty-loading", &test_loading_fixture);
}

const test_alternate_fixture = test_fixture.parse(@embedFile("testdata/kitty-alternate-v1.hex"));

test "golden snapshot with an image on the alternate screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testTerminal(4, 2);
    defer t.deinit(testing.allocator);

    try testCommand(&t, "a=T,f=32,s=1,v=1,i=1,C=1,q=2", &testPixels(4, .{ 1, 1, 1, 255 }));
    _ = try t.switchScreen(.alternate);
    try testCommand(&t, "a=T,f=24,s=1,v=1,i=1,C=1,q=2", &.{ 2, 2, 2 });
    try testGolden(&t, "kitty-alternate", &test_alternate_fixture);
}

/// One framed record within an encoded snapshot.
const TestRecord = struct {
    start: usize,
    end: usize,
    tag: record.Tag,
};

/// Split an encoded snapshot into its records, after the envelope.
fn testRecords(bytes: []const u8) ![]TestRecord {
    var result: std.ArrayList(TestRecord) = .empty;
    errdefer result.deinit(testing.allocator);
    var offset: usize = @import("envelope.zig").encoded_len;
    while (offset < bytes.len) {
        const tag = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const len = std.mem.readInt(u32, bytes[offset + 2 ..][0..4], .little);
        const end = offset + record.Header.len + len;
        try result.append(testing.allocator, .{
            .start = offset,
            .end = end,
            .tag = @fromBackingInt(@intCast(tag)),
        });
        offset = end;
    }
    return result.toOwnedSlice(testing.allocator);
}

fn testIsKittyTag(tag: record.Tag) bool {
    return switch (tag) {
        .kitty_image_storage,
        .kitty_image_payload,
        .kitty_image_page_placements,
        => true,
        else => false,
    };
}

/// The snapshot without its Kitty graphics records: what a terminal with
/// the same content but no images encodes to.
fn testStripKitty(bytes: []const u8) ![]u8 {
    const records = try testRecords(bytes);
    defer testing.allocator.free(records);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(testing.allocator);
    try result.appendSlice(testing.allocator, bytes[0..records[0].start]);
    for (records) |r| {
        if (testIsKittyTag(r.tag)) continue;
        try result.appendSlice(testing.allocator, bytes[r.start..r.end]);
    }
    return result.toOwnedSlice(testing.allocator);
}

/// The snapshot with an unknown record before every record, including
/// before FINISH, so one appears in every position between records.
fn testInsertUnknown(bytes: []const u8) ![]u8 {
    const records = try testRecords(bytes);
    defer testing.allocator.free(records);
    var result: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer result.deinit();
    try result.writer.writeAll(bytes[0..records[0].start]);
    for (records, 0..) |r, i| {
        // Vary the tags and lengths, including an empty payload.
        var payload: [8]u8 = @splat(@intCast(i));
        try record.testWriteRaw(
            &result.writer,
            @intCast(0x4000 + i),
            payload[0 .. i % payload.len],
        );
        try result.writer.writeAll(bytes[r.start..r.end]);
    }
    return result.toOwnedSlice();
}

test "a terminal without images encodes no Kitty graphics records" {
    var t = try testTerminal(4, 2);
    defer t.deinit(testing.allocator);
    const before = try testEncode(&t);
    defer testing.allocator.free(before);
    const records = try testRecords(before);
    defer testing.allocator.free(records);
    for (records) |r| try testing.expect(!testIsKittyTag(r.tag));

    // Transmitting and deleting an image changes storage counters that
    // are not encoded when the storage is empty again.
    if (comptime build_options.kitty_graphics) {
        try testCommand(&t, "a=t,f=32,s=1,v=1,i=1,q=2", &testPixels(4, .{ 1, 2, 3, 4 }));
        try testCommand(&t, "a=t,f=32,s=1,v=1,I=4,q=2", &testPixels(4, .{ 1, 2, 3, 4 }));
        try testCommand(&t, "a=p,i=1,C=1,q=2", "");
        try testing.expect(t.screens.active.kitty_images.images.count() == 2);
        testFeed(&t, "\x1b_Ga=d,d=I,i=1,q=2\x1b\\\x1b_Ga=d,d=N,I=4,q=2\x1b\\");
        try testing.expect(t.screens.active.kitty_images.images.count() == 0);
        try testing.expect(t.screens.active.kitty_images.next_internal_placement_id != 0);
    }
    const after = try testEncode(&t);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "Kitty graphics records are skipped without Kitty graphics support" {
    // Every golden snapshot that carries images.
    const fixtures = [_][]const u8{
        &test_placed_fixture,
        &test_source_rect_fixture,
        &test_virtual_fixture,
        &test_relative_fixture,
        &test_history_fixture,
        &test_animation_fixture,
        &test_loading_fixture,
        &test_alternate_fixture,
    };
    for (fixtures) |fixture| {
        const stripped = try testStripKitty(fixture);
        defer testing.allocator.free(stripped);
        try testing.expect(stripped.len < fixture.len);

        // With Kitty graphics compiled out, the image records are unknown
        // and the decoded terminal is exactly the one without them. With
        // it, the image-free snapshot is still a valid snapshot of the
        // same terminal content without its images.
        var restored = try testDecode(
            if (comptime build_options.kitty_graphics) stripped else fixture,
            test_decode_options,
        );
        defer restored.deinit(testing.allocator);
        const reencoded = try testEncode(&restored);
        defer testing.allocator.free(reencoded);
        try testing.expectEqualSlices(u8, stripped, reencoded);
    }
}

const test_unknown_fixture = test_fixture.parse(@embedFile("testdata/unknown-records-v1.hex"));

test "golden snapshot with an unknown record in every position" {
    // The fixture is the history golden, which has Kitty graphics records
    // of every kind, with unknown records interleaved everywhere.
    const expected = try testInsertUnknown(&test_history_fixture);
    defer testing.allocator.free(expected);
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/unknown-records-v1.hex",
        "snapshot_fixture-unknown-records-v1.hex",
        &test_unknown_fixture,
        expected,
    );

    // Unknown records are skipped wherever they appear.
    var restored = try testDecode(&test_unknown_fixture, test_decode_options);
    defer restored.deinit(testing.allocator);
    const reencoded = try testEncode(&restored);
    defer testing.allocator.free(reencoded);
    if (comptime build_options.kitty_graphics) {
        try testing.expectEqualSlices(u8, &test_history_fixture, reencoded);
    } else {
        const stripped = try testStripKitty(&test_history_fixture);
        defer testing.allocator.free(stripped);
        try testing.expectEqualSlices(u8, stripped, reencoded);
    }

    // The same holds for the incremental decoder.
    {
        var source_reader: std.Io.Reader = .fixed(&test_unknown_fixture);
        var decoder: snapshot.Decoder = .init(&source_reader);
        var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
        defer decoded.deinit(testing.allocator);
        var incremental = decoded.toOwned();
        defer incremental.deinit(testing.allocator);
        while (try decoder.next(testing.allocator, &incremental)) |_| {}
        const incremental_bytes = try testEncode(&incremental);
        defer testing.allocator.free(incremental_bytes);
        try testing.expectEqualSlices(u8, reencoded, incremental_bytes);
    }

    // A corrupted unknown record still fails its CRC, in every position.
    const records = try testRecords(&test_unknown_fixture);
    defer testing.allocator.free(records);
    for (records) |r| {
        if (r.tag.known()) continue;
        const corrupted = try testing.allocator.dupe(u8, &test_unknown_fixture);
        defer testing.allocator.free(corrupted);
        corrupted[r.start] ^= 0x01;
        try testing.expectError(
            error.InvalidChecksum,
            testDecode(corrupted, test_decode_options),
        );
    }
}

test "decode with a smaller limit keeps the newest images" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testTerminal(4, 3);
    defer t.deinit(testing.allocator);

    // Three 64-byte images, oldest first. The oldest has a placement with
    // a relative child on another image.
    const pixels = testPixels(64, .{ 5, 5, 5, 255 });
    try testCommand(&t, "a=T,f=32,s=4,v=4,i=1,p=1,C=1,q=2", &pixels);
    try testCommand(&t, "a=T,f=32,s=4,v=4,i=2,p=1,C=1,q=2", &pixels);
    try testCommand(&t, "a=T,f=32,s=4,v=4,i=3,p=1,C=1,q=2", &pixels);
    try testCommand(&t, "a=p,i=3,p=2,P=1,Q=1,H=1,q=2", "");
    try testing.expectEqual(4, t.screens.active.kitty_images.placements.count());
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    var restored = try testDecode(encoded, .{
        .max_continuation_bytes = 0,
        .kitty_image_storage_limit = 150,
    });
    defer restored.deinit(testing.allocator);
    const storage = &restored.screens.active.kitty_images;
    try testing.expectEqual(150, storage.total_limit);
    try testing.expectEqual(2, storage.images.count());
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqualSlices(u8, &pixels, storage.imageById(2).?.data.bytes().?);
    try testing.expectEqualSlices(u8, &pixels, storage.imageById(3).?.data.bytes().?);

    // The placement of the dropped image and its relative child are gone.
    try testing.expectEqual(2, storage.placements.count());
    var it = storage.placements.keyIterator();
    while (it.next()) |key| try testing.expect(key.image_id != 1);
    try testing.expectEqual(128, storage.total_bytes);

    // A limit too small for any image keeps none. The pixels for those
    // images are then skipped without an error.
    var empty = try testDecode(encoded, .{
        .max_continuation_bytes = 0,
        .kitty_image_storage_limit = 10,
    });
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(0, empty.screens.active.kitty_images.images.count());
    try testing.expectEqual(0, empty.screens.active.kitty_images.total_bytes);
}

test "incremental decode restores images at READY and payloads after" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testAnimationTerminal();
    defer t.deinit(testing.allocator);
    try testCommand(&t, "a=T,f=32,s=8,v=8,i=9,C=1,q=2", &testPixels(256, .{ 3, 3, 3, 255 }));
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    var source: std.Io.Reader = .fixed(encoded);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    // At READY every image and placement exists, with pending pixels
    // reserved against the limit, and the animation does not play.
    const counts = decoded.kitty.get(.primary);
    try testing.expectEqual(2, counts.images);
    try testing.expectEqual(256 + 3 * 8, counts.pending_bytes);
    try testing.expectEqual(0, decoded.kitty.get(.alternate).images);
    const storage = &restored.screens.active.kitty_images;
    try testing.expectEqual(t.screens.active.kitty_images.total_bytes, storage.total_bytes);
    try testing.expect(storage.imageById(5).?.data.isPending());
    try testing.expect(storage.imageById(5).?.renderData().isPending());
    try testing.expect(storage.animationTick(testing.io, 0) == null);
    try testing.expectEqual(2, storage.placements.count());

    // Payloads arrive one per call: the displayed frame of every visible
    // image first, oldest image first, then the other animation frames.
    const expected = [_]struct { id: u32, frame: u32, bytes: usize }{
        .{ .id = 5, .frame = 2, .bytes = 8 },
        .{ .id = 9, .frame = 1, .bytes = 256 },
        .{ .id = 5, .frame = 1, .bytes = 8 },
        .{ .id = 5, .frame = 3, .bytes = 8 },
    };
    for (expected, 0..) |e, i| {
        const progress = (try decoder.next(testing.allocator, &restored)).?;
        try testing.expectEqualDeep(snapshot.Decoder.Progress{ .image = .{
            .key = .primary,
            .image_id = e.id,
            .frame = e.frame,
            .bytes = e.bytes,
        } }, progress);

        // The animation waits for its last frame.
        const playing = storage.animationTick(testing.io, 1000) != null;
        try testing.expectEqual(i == expected.len - 1, playing);
    }
    try testing.expect(try decoder.next(testing.allocator, &restored) == null);
    try expectStorageEqual(&t, &restored, .primary);
}

test "a payload for an image replaced after READY is dropped" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testPlacedTerminal();
    defer t.deinit(testing.allocator);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    var source: std.Io.Reader = .fixed(encoded);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    // Live input sends a new image with the same ID before the payload
    // arrives. The payload's pixels belong to the old image.
    const live = testPixels(4, .{ 0, 0, 0, 255 });
    try testCommand(&restored, "a=t,f=32,s=1,v=1,i=1,q=2", &live);

    const progress = (try decoder.next(testing.allocator, &restored)).?.image;
    try testing.expectEqual(1, progress.image_id);
    try testing.expectEqual(0, progress.bytes);
    try testing.expect(try decoder.next(testing.allocator, &restored) == null);

    const storage = &restored.screens.active.kitty_images;
    try testing.expectEqualSlices(u8, &live, storage.imageById(1).?.data.bytes().?);
    try testing.expectEqual(4, storage.total_bytes);
}

test "a dropped history page drops its placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testHistoryPlacedTerminal();
    defer t.deinit(testing.allocator);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    // Without changes, the incremental decoder restores every history
    // placement with its page.
    {
        var source: std.Io.Reader = .fixed(encoded);
        var decoder: snapshot.Decoder = .init(&source);
        var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        const storage = &restored.screens.active.kitty_images;
        try testing.expectEqual(1, storage.placements.count());

        // The payload comes first, then each history page with its
        // placements.
        _ = (try decoder.next(testing.allocator, restored)).?.image;
        const newest = (try decoder.next(testing.allocator, restored)).?.page;
        try testing.expectEqual(2, newest.rows);
        try testing.expectEqual(2, storage.placements.count());
        const oldest = (try decoder.next(testing.allocator, restored)).?.page;
        try testing.expectEqual(2, oldest.rows);
        try testing.expectEqual(4, storage.placements.count());
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
        try expectStorageEqual(&t, restored, .primary);
    }

    // After a resize, history pages and their placement records are read
    // but dropped, and FINISH still validates.
    {
        var source: std.Io.Reader = .fixed(encoded);
        var decoder: snapshot.Decoder = .init(&source);
        var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
        defer decoded.deinit(testing.allocator);
        var restored = decoded.toOwned();
        defer restored.deinit(testing.allocator);
        try restored.resize(testing.allocator, .{ .cols = 3, .rows = 2 });

        var pages: usize = 0;
        while (try decoder.next(testing.allocator, &restored)) |progress| {
            const page = switch (progress) {
                .page => |page| page,
                .image => continue,
            };
            try testing.expectEqual(0, page.rows);
            pages += 1;
        }
        try testing.expectEqual(2, pages);
        const storage = &restored.screens.active.kitty_images;
        var it = storage.placements.keyIterator();
        while (it.next()) |key| try testing.expectEqual(
            PlacementId{ .tag = .external, .id = 3 },
            key.placement_id,
        );
    }
}

test "an image placed only in history arrives with its page" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testHistoryTerminal();
    defer t.deinit(testing.allocator);

    // One image on the oldest history page, and one that is not placed.
    try testCommand(&t, "a=t,f=32,s=1,v=1,i=4,q=2", &testPixels(4, .{ 9, 9, 9, 255 }));
    try testCommand(&t, "a=t,f=32,s=1,v=1,i=5,q=2", &testPixels(4, .{ 7, 7, 7, 255 }));
    const oldest = t.screens.active.pages.pages.first.?;
    try testPlace(&t, oldest, 4, 1, 1, 1);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    // The placed image's pixels follow its page's placements, and the
    // unplaced image's pixels come after all history.
    const records = try testRecords(encoded);
    defer testing.allocator.free(records);
    var tags: std.ArrayList(record.Tag) = .empty;
    defer tags.deinit(testing.allocator);
    var after_ready = false;
    for (records) |r| {
        if (after_ready) try tags.append(testing.allocator, r.tag);
        if (r.tag == .ready) after_ready = true;
    }
    try testing.expectEqualSlices(record.Tag, &.{
        .history,
        .page,
        .page,
        .kitty_image_page_placements,
        .kitty_image_payload,
        .kitty_image_payload,
        .finish,
    }, tags.items);

    // The incremental decoder sees the same order, and the placement is
    // there by the time its pixels arrive.
    var source: std.Io.Reader = .fixed(encoded);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
    defer decoded.deinit(testing.allocator);
    const restored = &decoded.terminal.?;
    const storage = &restored.screens.active.kitty_images;
    try testing.expectEqual(0, storage.placements.count());
    for (0..2) |_| _ = (try decoder.next(testing.allocator, restored)).?.page;
    try testing.expectEqual(1, storage.placements.count());
    try testing.expect(storage.imageById(4).?.data.isPending());
    const first = (try decoder.next(testing.allocator, restored)).?.image;
    try testing.expectEqual(4, first.image_id);
    try testing.expectEqual(4, first.bytes);
    const second = (try decoder.next(testing.allocator, restored)).?.image;
    try testing.expectEqual(5, second.image_id);
    try testing.expect(try decoder.next(testing.allocator, restored) == null);
    try expectStorageEqual(&t, restored, .primary);
}

test "history placements restore onto compressed history pages" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testHistoryPlacedTerminal();
    defer t.deinit(testing.allocator);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    var restored = try testDecode(encoded, .{
        .max_continuation_bytes = 1024,
        .compress_history = true,
    });
    defer restored.deinit(testing.allocator);
    try expectStorageEqual(&t, &restored, .primary);
    try testing.expectEqual(4, restored.screens.active.kitty_images.placements.count());
}

test "a restored in-progress load continues the chunked transmission" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testTerminal(4, 2);
    defer t.deinit(testing.allocator);
    try testCommand(
        &t,
        "a=T,f=32,s=2,v=2,i=6,c=1,r=1,q=2,m=1",
        test_loading_pixels[0..test_loading_cut],
    );

    var restored = try testDecode(&test_loading_fixture, test_decode_options);
    defer restored.deinit(testing.allocator);

    // The rest of the transmission completes and displays the image on
    // both terminals alike.
    for ([_]*Terminal{ &t, &restored }) |target| {
        try testCommand(target, "m=0", test_loading_pixels[test_loading_cut..]);
        const storage = &target.screens.active.kitty_images;
        try testing.expect(storage.loading == null);
        try testing.expectEqualSlices(
            u8,
            &test_loading_pixels,
            storage.imageById(6).?.data.bytes().?,
        );
        try testing.expectEqual(1, storage.placements.count());
    }
    try expectStorageEqual(&t, &restored, .primary);
}

test "a payload with fewer pixels than it declares fails" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const records = try testRecords(&test_placed_fixture);
    defer testing.allocator.free(records);
    const payload = for (records) |r| {
        if (r.tag == .kitty_image_payload) break r;
    } else unreachable;

    // Drop the last pixel byte and fix up the record's length and CRC, so
    // the record is well formed but shorter than its declared pixels.
    var short: std.Io.Writer.Allocating = .init(testing.allocator);
    defer short.deinit();
    try short.writer.writeAll(test_placed_fixture[0..payload.start]);
    const body = test_placed_fixture[payload.start + record.Header.len .. payload.end - 1];
    try record.testWriteRaw(
        &short.writer,
        @backingInt(record.Tag.kitty_image_payload),
        body,
    );
    try short.writer.writeAll(test_placed_fixture[payload.end..]);

    try testing.expectError(
        error.EndOfStream,
        testDecode(short.written(), test_decode_options),
    );
}

test "completing a placeholder image's payload updates the render state" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testVirtualTerminal();
    defer t.deinit(testing.allocator);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    var source: std.Io.Reader = .fixed(encoded);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    var state: RenderState = .empty;
    defer state.deinit(testing.allocator);

    // The pending image draws nothing yet, even though its placeholder
    // characters are on screen.
    try state.update(testing.allocator, &restored);
    var it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);

    // The payload completes the image and changes the storage generation,
    // so the next update looks at the placeholders again and finds the
    // image.
    const generation = restored.screens.active.kitty_images.generation;
    const progress = (try decoder.next(testing.allocator, &restored)).?.image;
    try testing.expectEqual(16, progress.bytes);
    try testing.expect(restored.screens.active.kitty_images.generation != generation);
    try state.update(testing.allocator, &restored);
    it = state.imagePlacementIterator();
    const placement = it.next().?;
    try testing.expectEqual(3, placement.image_id);
    try testing.expectEqual(2, placement.cols);
    try testing.expect(it.next() == null);
}

/// `bytes` with its one KITTY_IMAGE_PAYLOAD record moved to just before the
/// record at `position`, counted among the other records.
fn testMovePayload(bytes: []const u8, position: usize) ![]u8 {
    const records = try testRecords(bytes);
    defer testing.allocator.free(records);
    const payload = for (records) |r| {
        if (r.tag == .kitty_image_payload) break r;
    } else unreachable;

    var result: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer result.deinit();
    try result.writer.writeAll(bytes[0..records[0].start]);
    var index: usize = 0;
    for (records) |r| {
        if (r.tag == .kitty_image_payload) continue;
        if (index == position) try result.writer.writeAll(bytes[payload.start..payload.end]);
        try result.writer.writeAll(bytes[r.start..r.end]);
        index += 1;
    }
    return result.toOwnedSlice();
}

const test_payload_in_history_fixture = test_fixture.parse(@embedFile("testdata/kitty-payload-in-history-v1.hex"));

test "a payload may come anywhere after READY" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testHistoryPlacedTerminal();
    defer t.deinit(testing.allocator);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    // The positions of READY and FINISH among the records other than the
    // payload.
    var others: std.ArrayList(record.Tag) = .empty;
    defer others.deinit(testing.allocator);
    {
        const records = try testRecords(encoded);
        defer testing.allocator.free(records);
        for (records) |r| {
            if (r.tag != .kitty_image_payload) try others.append(testing.allocator, r.tag);
        }
    }
    const ready = std.mem.indexOfScalar(record.Tag, others.items, .ready).?;
    const finish = others.items.len - 1;
    try testing.expectEqual(.finish, others.items[finish]);

    // Try the payload in front of every record after READY, up to and
    // including FINISH. Each restores the same terminal, except a payload
    // between a PAGE and its KITTY_IMAGE_PAGE_PLACEMENTS, which is not
    // allowed.
    for (ready + 1..finish + 1) |position| {
        const moved = try testMovePayload(encoded, position);
        defer testing.allocator.free(moved);
        if (others.items[position] == .kitty_image_page_placements) {
            try testing.expectError(
                error.UnexpectedRecordTag,
                testDecode(moved, test_decode_options),
            );
            continue;
        }

        var restored = try testDecode(moved, test_decode_options);
        defer restored.deinit(testing.allocator);
        try expectStorageEqual(&t, &restored, .primary);
    }

    // A golden fixture with the payload between two history pages, so the
    // schema check sees a payload inside HISTORY too.
    const index = for (others.items, 0..) |tag, i| {
        if (i > ready and tag == .page and others.items[i - 1] == .kitty_image_page_placements) break i;
    } else unreachable;
    const expected = try testMovePayload(encoded, index);
    defer testing.allocator.free(expected);
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/kitty-payload-in-history-v1.hex",
        "snapshot_fixture-kitty-payload-in-history-v1.hex",
        &test_payload_in_history_fixture,
        expected,
    );
}

test "KITTY_IMAGE_STORAGE must belong to the screen before it" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testPlacedTerminal();
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;

    // Write the primary screen's storage, but name the alternate screen.
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    var stream: record.Writer = .init(testing.allocator, &encoded.writer);
    defer stream.deinit();
    try @import("envelope.zig").encode(stream.writer());
    try @import("terminal.zig").encode(&t, &stream);
    try @import("screen.zig").encode(primary, .primary, &stream);
    var plan = (try ScreenPlan.init(testing.allocator, primary, .alternate)).?;
    defer plan.deinit();
    try plan.encodeStorage(&stream);
    try @import("continuation.zig").encode(.ground, &stream);

    try testing.expectError(
        error.UnexpectedKittyKey,
        testDecode(encoded.written(), test_decode_options),
    );
}

test "history placements skip an image replaced after READY" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try testHistoryPlacedTerminal();
    defer t.deinit(testing.allocator);
    const encoded = try testEncode(&t);
    defer testing.allocator.free(encoded);

    var source: std.Io.Reader = .fixed(encoded);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    // Live input sends a new image with the same ID before the history
    // pages arrive. It is a different image, so it gets none of the
    // snapshot's history placements.
    const live = testPixels(4, .{ 0, 0, 0, 255 });
    try testCommand(&restored, "a=t,f=32,s=1,v=1,i=4,q=2", &live);
    while (try decoder.next(testing.allocator, &restored)) |_| {}

    const storage = &restored.screens.active.kitty_images;
    try testing.expectEqualSlices(u8, &live, storage.imageById(4).?.data.bytes().?);
    try testing.expectEqual(0, storage.placements.count());
}
