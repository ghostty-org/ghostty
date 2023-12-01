//! OpenGL bindings.
//!
//! These are purpose-built for usage within this program. While they closely
//! align with the OpenGL C APIs, they aren't meant to be general purpose,
//! they aren't meant to have 100% API coverage, and they aren't meant to
//! be hyper-performant.
//!
//! For performance-intensive or unsupported aspects of OpenGL, the C
//! API is exposed via the `c` constant.
//!
//! WARNING: Lots of performance improvements that we can make with Zig
//! comptime help. I'm deferring this until later but have some fun ideas.

pub const c = @import("c.zig");
pub const glad = @import("glad.zig");
pub usingnamespace @import("draw.zig");

pub const ext = @import("extensions.zig");
pub const Buffer = @import("Buffer.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const Program = @import("Program.zig");
pub const Shader = @import("Shader.zig");
pub const Texture = @import("Texture.zig");
pub const VertexArray = @import("VertexArray.zig");
