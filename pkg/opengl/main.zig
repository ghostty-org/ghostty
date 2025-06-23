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

pub const c = @import("c.zig").c;
pub const glad = @import("glad.zig");
pub const ext = @import("extensions.zig");
pub const Buffer = @import("Buffer.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const Renderbuffer = @import("Renderbuffer.zig");
pub const Program = @import("Program.zig");
pub const Shader = @import("Shader.zig");
pub const Texture = @import("Texture.zig");
pub const VertexArray = @import("VertexArray.zig");

pub const errors = @import("errors.zig");

pub const Primitive = @import("primitives.zig").Primitive;

const draw = @import("draw.zig");

pub const blendFunc = draw.blendFunc;
pub const clear = draw.clear;
pub const clearColor = draw.clearColor;
pub const drawArrays = draw.drawArrays;
pub const drawArraysInstanced = draw.drawArraysInstanced;
pub const drawElements = draw.drawElements;
pub const drawElementsInstanced = draw.drawElementsInstanced;
pub const enable = draw.enable;
pub const disable = draw.disable;
pub const frontFace = draw.frontFace;
pub const pixelStore = draw.pixelStore;
pub const viewport = draw.viewport;
pub const flush = draw.flush;
pub const finish = draw.finish;
