//! Wrapper for `VkSampler` — the immutable filter / wrap configuration
//! the GPU uses when sampling a texture.
//!
//! libghostty doesn't share samplers across textures (the OpenGL
//! backend already creates one per texture-shaped need); we keep the
//! same per-callsite ownership model so the renderer interface
//! matches.
//!
//! Counterpart: `src/renderer/opengl/Sampler.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// Texel filter mode. Maps 1:1 to `VkFilter` (which is a `c_uint`).
pub const Filter = enum(c_uint) {
    nearest = vk.VK_FILTER_NEAREST,
    linear = vk.VK_FILTER_LINEAR,
};

/// Texture coordinate wrap mode. Maps 1:1 to `VkSamplerAddressMode`
/// (a `c_uint`).
pub const AddressMode = enum(c_uint) {
    repeat = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
    mirrored_repeat = vk.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
    clamp_to_edge = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    clamp_to_border = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
};

/// Sampler construction parameters. The same shape as the OpenGL
/// backend's `Sampler.Options` (so generic.zig can call
/// `Sampler.init(api.samplerOptions())` against either backend), with
/// a `device` reference so we can call `vkCreateSampler` against the
/// host's VkDevice without threading a global through.
pub const Options = struct {
    device: *const Device,
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: AddressMode,
    wrap_t: AddressMode,

    /// Vulkan-only: enable sampling with non-normalized texel
    /// coordinates (so `texture(s, p)` reads texel `p` directly
    /// rather than mapping `[0,1] x [0,1]` over the image).
    ///
    /// This is what makes `sampler2D` behave like the OpenGL
    /// `sampler2DRect` the renderer's text shaders were originally
    /// authored against (after `vulkanizeGlsl` rewrites the type
    /// name). Vulkan imposes a long list of co-requirements when
    /// this is enabled — `init` forces them rather than rejecting
    /// inputs that violate them:
    ///
    ///   - `magFilter == minFilter`  (we use `mag_filter`)
    ///   - `mipmapMode = NEAREST`
    ///   - `addressModeU/V` must be CLAMP_TO_EDGE / CLAMP_TO_BORDER
    ///     (we force CLAMP_TO_EDGE, ignoring `wrap_s/wrap_t`)
    ///   - `anisotropyEnable = FALSE`
    ///   - `compareEnable = FALSE`
    ///   - `minLod == maxLod == 0`
    ///
    /// The bound image view must also be 1D or 2D with one mip
    /// level and one array layer — true for the glyph atlas.
    unnormalized_coordinates: bool = false,
};

pub const Error = error{
    /// `vkCreateSampler` returned a non-success status. Logged with
    /// the raw `VkResult` value.
    VulkanFailed,
};

sampler: vk.VkSampler,
device: *const Device,

/// Create a sampler against the host's VkDevice. The sampler is
/// destroyed in `deinit`; libghostty owns this handle's lifetime.
pub fn init(opts: Options) Error!Self {
    const unnorm = opts.unnormalized_coordinates;
    const info: vk.VkSamplerCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        // When unnormalized, magFilter must equal minFilter (the
        // sampling stage doesn't get to pick between them). Force
        // both to `mag_filter` rather than rejecting at the caller.
        .magFilter = @intFromEnum(opts.mag_filter),
        .minFilter = if (unnorm)
            @intFromEnum(opts.mag_filter)
        else
            @intFromEnum(opts.min_filter),
        // The glyph atlases are 2D textures without mips; the
        // renderer doesn't request mipmaps and the value here is
        // ignored when `lodMin == lodMax == 0`. Unnormalized
        // sampling requires NEAREST; we use LINEAR otherwise for
        // forward-compatibility if we ever generate atlas mips.
        .mipmapMode = if (unnorm)
            vk.VK_SAMPLER_MIPMAP_MODE_NEAREST
        else
            vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        // Unnormalized requires CLAMP_TO_EDGE or CLAMP_TO_BORDER;
        // we don't have a use for the latter, so force CLAMP_TO_EDGE.
        .addressModeU = if (unnorm)
            vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        else
            @intFromEnum(opts.wrap_s),
        .addressModeV = if (unnorm)
            vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        else
            @intFromEnum(opts.wrap_t),
        // 2D textures never sample in W; the renderer ignores it. The
        // value still has to be valid — pick CLAMP_TO_EDGE.
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .mipLodBias = 0,
        // Anisotropy is a per-physical-device feature toggle; the
        // terminal grid doesn't benefit from it and gating on the
        // feature flag adds host coordination noise. Skip. (Also a
        // hard requirement for unnormalized sampling.)
        .anisotropyEnable = vk.VK_FALSE,
        .maxAnisotropy = 1,
        .compareEnable = vk.VK_FALSE,
        .compareOp = vk.VK_COMPARE_OP_ALWAYS,
        .minLod = 0,
        .maxLod = 0,
        .borderColor = vk.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        .unnormalizedCoordinates = if (unnorm) vk.VK_TRUE else vk.VK_FALSE,
    };

    var sampler: vk.VkSampler = undefined;
    const result = opts.device.dispatch.createSampler(
        opts.device.device,
        &info,
        null,
        &sampler,
    );
    if (result != vk.VK_SUCCESS) {
        log.err("vkCreateSampler failed: result={}", .{result});
        return error.VulkanFailed;
    }

    return .{
        .sampler = sampler,
        .device = opts.device,
    };
}

pub fn deinit(self: Self) void {
    self.device.dispatch.destroySampler(self.device.device, self.sampler, null);
}

test {
    std.testing.refAllDecls(@This());
}
