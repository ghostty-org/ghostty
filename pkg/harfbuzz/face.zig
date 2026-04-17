const std = @import("std");
const c = @import("c");

/// A font face is an object that represents a single face from within a font family.
///
/// More precisely, a font face represents a single face in a binary font file.
/// Font faces are typically built from a binary blob and a face index.
/// Font faces are used to create fonts.
pub const Face = struct {
    handle: *c.hb_face_t,

    /// Decreases the reference count on a face object. When the reference
    /// count reaches zero, the face is destroyed, freeing all memory.
    pub fn destroy(self: *Face) void {
        c.hb_face_destroy(self.handle);
    }
};
