const blob = @import("blob.zig");
const buffer = @import("buffer.zig");
const common = @import("common.zig");
const errors = @import("errors.zig");
const face = @import("face.zig");
const font = @import("font.zig");
const shapepkg = @import("shape.zig");
const versionpkg = @import("version.zig");

pub const c = @import("c.zig").c;
pub const freetype = @import("freetype.zig");
pub const coretext = @import("coretext.zig");
pub const MemoryMode = blob.MemoryMode;
pub const Blob = blob.Blob;
pub const Buffer = buffer.Buffer;
pub const GlyphPosition = buffer.GlyphPosition;
pub const Direction = common.Direction;
pub const Script = common.Script;
pub const Language = common.Language;
pub const Feature = common.Feature;
pub const Face = face.Face;
pub const Font = font.Font;
pub const shape = shapepkg.shape;
pub const Version = versionpkg.Version;
pub const version = versionpkg.version;
pub const versionAtLeast = versionpkg.versionAtLeast;
pub const versionString = versionpkg.versionString;

test {
    @import("std").testing.refAllDecls(@This());
}
