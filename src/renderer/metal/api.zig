//! This file contains the definitions of the Metal API that we use.
//!
//! Because the online Apple developer docs have recently (as of January 2025)
//! been changed to hide enum values, `Metal-cpp` has been used as a reference
//! source instead.
//!
//! Ref: https://developer.apple.com/metal/cpp/

/// https://developer.apple.com/documentation/metal/mtlcommandbufferstatus?language=objc
pub const MTLCommandBufferStatus = enum(c_ulong) {
    not_enqueued = 0,
    enqueued = 1,
    committed = 2,
    scheduled = 3,
    completed = 4,
    @"error" = 5,
    _,
};

/// https://developer.apple.com/documentation/metal/mtlloadaction?language=objc
pub const MTLLoadAction = enum(c_ulong) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

/// https://developer.apple.com/documentation/metal/mtlstoreaction?language=objc
pub const MTLStoreAction = enum(c_ulong) {
    dont_care = 0,
    store = 1,
    multisample_resolve = 2,
    store_and_multisample_resolve = 3,
    unknown = 4,
    custom_sample_depth_store = 5,
};

/// https://developer.apple.com/documentation/metal/mtlresourceoptions?language=objc
pub const MTLResourceOptions = packed struct(c_ulong) {
    /// https://developer.apple.com/documentation/metal/mtlcpucachemode?language=objc
    cpu_cache_mode: CPUCacheMode = .default,
    /// https://developer.apple.com/documentation/metal/mtlstoragemode?language=objc
    storage_mode: StorageMode,
    /// https://developer.apple.com/documentation/metal/mtlhazardtrackingmode?language=objc
    hazard_tracking_mode: HazardTrackingMode = .default,

    _pad: @Type(.{
        .int = .{ .signedness = .unsigned, .bits = @bitSizeOf(c_ulong) - 10 },
    }) = 0,

    pub const CPUCacheMode = enum(u4) {
        default = 0,
        write_combined = 1,
    };

    pub const StorageMode = enum(u4) {
        shared = 0,
        managed = 1,
        private = 2,
        memoryless = 3,
    };

    pub const HazardTrackingMode = enum(u2) {
        default = 0,
        untracked = 1,
        tracked = 2,
    };
};

/// https://developer.apple.com/documentation/metal/mtlprimitivetype?language=objc
pub const MTLPrimitiveType = enum(c_ulong) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

/// https://developer.apple.com/documentation/metal/mtlindextype?language=objc
pub const MTLIndexType = enum(c_ulong) {
    uint16 = 0,
    uint32 = 1,
};

/// https://developer.apple.com/documentation/metal/mtlvertexformat?language=objc
pub const MTLVertexFormat = enum(c_ulong) {
    invalid = 0,
    uchar2 = 1,
    uchar3 = 2,
    uchar4 = 3,
    char2 = 4,
    char3 = 5,
    char4 = 6,
    uchar2normalized = 7,
    uchar3normalized = 8,
    uchar4normalized = 9,
    char2normalized = 10,
    char3normalized = 11,
    char4normalized = 12,
    ushort2 = 13,
    ushort3 = 14,
    ushort4 = 15,
    short2 = 16,
    short3 = 17,
    short4 = 18,
    ushort2normalized = 19,
    ushort3normalized = 20,
    ushort4normalized = 21,
    short2normalized = 22,
    short3normalized = 23,
    short4normalized = 24,
    half2 = 25,
    half3 = 26,
    half4 = 27,
    float = 28,
    float2 = 29,
    float3 = 30,
    float4 = 31,
    int = 32,
    int2 = 33,
    int3 = 34,
    int4 = 35,
    uint = 36,
    uint2 = 37,
    uint3 = 38,
    uint4 = 39,
    int1010102normalized = 40,
    uint1010102normalized = 41,
    uchar4normalized_bgra = 42,
    uchar = 45,
    char = 46,
    ucharnormalized = 47,
    charnormalized = 48,
    ushort = 49,
    short = 50,
    ushortnormalized = 51,
    shortnormalized = 52,
    half = 53,
    floatrg11b10 = 54,
    floatrgb9e5 = 55,
};

/// https://developer.apple.com/documentation/metal/mtlvertexstepfunction?language=objc
pub const MTLVertexStepFunction = enum(c_ulong) {
    constant = 0,
    per_vertex = 1,
    per_instance = 2,
    per_patch = 3,
    per_patch_control_point = 4,
};

/// https://developer.apple.com/documentation/metal/mtlpixelformat?language=objc
pub const MTLPixelFormat = enum(c_ulong) {
    invalid = 0,
    a8unorm = 1,
    r8unorm = 10,
    r8unorm_srgb = 11,
    r8snorm = 12,
    r8uint = 13,
    r8sint = 14,
    r16unorm = 20,
    r16snorm = 22,
    r16uint = 23,
    r16sint = 24,
    r16float = 25,
    rg8unorm = 30,
    rg8unorm_srgb = 31,
    rg8snorm = 32,
    rg8uint = 33,
    rg8sint = 34,
    b5g6r5unorm = 40,
    a1bgr5unorm = 41,
    abgr4unorm = 42,
    bgr5a1unorm = 43,
    r32uint = 53,
    r32sint = 54,
    r32float = 55,
    rg16unorm = 60,
    rg16snorm = 62,
    rg16uint = 63,
    rg16sint = 64,
    rg16float = 65,
    rgba8unorm = 70,
    rgba8unorm_srgb = 71,
    rgba8snorm = 72,
    rgba8uint = 73,
    rgba8sint = 74,
    bgra8unorm = 80,
    bgra8unorm_srgb = 81,
    rgb10a2unorm = 90,
    rgb10a2uint = 91,
    rg11b10float = 92,
    rgb9e5float = 93,
    bgr10a2unorm = 94,
    bgr10_xr = 554,
    bgr10_xr_srgb = 555,
    rg32uint = 103,
    rg32sint = 104,
    rg32float = 105,
    rgba16unorm = 110,
    rgba16snorm = 112,
    rgba16uint = 113,
    rgba16sint = 114,
    rgba16float = 115,
    bgra10_xr = 552,
    bgra10_xr_srgb = 553,
    rgba32uint = 123,
    rgba32sint = 124,
    rgba32float = 125,
    bc1_rgba = 130,
    bc1_rgba_srgb = 131,
    bc2_rgba = 132,
    bc2_rgba_srgb = 133,
    bc3_rgba = 134,
    bc3_rgba_srgb = 135,
    bc4_runorm = 140,
    bc4_rsnorm = 141,
    bc5_rgunorm = 142,
    bc5_rgsnorm = 143,
    bc6h_rgbfloat = 150,
    bc6h_rgbufloat = 151,
    bc7_rgbaunorm = 152,
    bc7_rgbaunorm_srgb = 153,
    pvrtc_rgb_2bpp = 160,
    pvrtc_rgb_2bpp_srgb = 161,
    pvrtc_rgb_4bpp = 162,
    pvrtc_rgb_4bpp_srgb = 163,
    pvrtc_rgba_2bpp = 164,
    pvrtc_rgba_2bpp_srgb = 165,
    pvrtc_rgba_4bpp = 166,
    pvrtc_rgba_4bpp_srgb = 167,
    eac_r11unorm = 170,
    eac_r11snorm = 172,
    eac_rg11unorm = 174,
    eac_rg11snorm = 176,
    eac_rgba8 = 178,
    eac_rgba8_srgb = 179,
    etc2_rgb8 = 180,
    etc2_rgb8_srgb = 181,
    etc2_rgb8a1 = 182,
    etc2_rgb8a1_srgb = 183,
    astc_4x4_srgb = 186,
    astc_5x4_srgb = 187,
    astc_5x5_srgb = 188,
    astc_6x5_srgb = 189,
    astc_6x6_srgb = 190,
    astc_8x5_srgb = 192,
    astc_8x6_srgb = 193,
    astc_8x8_srgb = 194,
    astc_10x5_srgb = 195,
    astc_10x6_srgb = 196,
    astc_10x8_srgb = 197,
    astc_10x10_srgb = 198,
    astc_12x10_srgb = 199,
    astc_12x12_srgb = 200,
    astc_4x4_ldr = 204,
    astc_5x4_ldr = 205,
    astc_5x5_ldr = 206,
    astc_6x5_ldr = 207,
    astc_6x6_ldr = 208,
    astc_8x5_ldr = 210,
    astc_8x6_ldr = 211,
    astc_8x8_ldr = 212,
    astc_10x5_ldr = 213,
    astc_10x6_ldr = 214,
    astc_10x8_ldr = 215,
    astc_10x10_ldr = 216,
    astc_12x10_ldr = 217,
    astc_12x12_ldr = 218,
    astc_4x4_hdr = 222,
    astc_5x4_hdr = 223,
    astc_5x5_hdr = 224,
    astc_6x5_hdr = 225,
    astc_6x6_hdr = 226,
    astc_8x5_hdr = 228,
    astc_8x6_hdr = 229,
    astc_8x8_hdr = 230,
    astc_10x5_hdr = 231,
    astc_10x6_hdr = 232,
    astc_10x8_hdr = 233,
    astc_10x10_hdr = 234,
    astc_12x10_hdr = 235,
    astc_12x12_hdr = 236,
    gbgr422 = 240,
    bgrg422 = 241,
    depth16unorm = 250,
    depth32float = 252,
    stencil8 = 253,
    depth24unorm_stencil8 = 255,
    depth32float_stencil8 = 260,
    x32_stencil8 = 261,
    x24_stencil8 = 262,
};

/// https://developer.apple.com/documentation/metal/mtlpurgeablestate?language=objc
pub const MTLPurgeableState = enum(c_ulong) {
    keep_current = 1,
    non_volatile = 2,
    @"volatile" = 3,
    empty = 4,
};

/// https://developer.apple.com/documentation/metal/mtlsamplerminmagfilter?language=objc
pub const MTLSamplerMinMagFilter = enum(c_ulong) {
    nearest = 0,
    linear = 1,
};

/// https://developer.apple.com/documentation/metal/mtlsampleraddressmode?language=objc
pub const MTLSamplerAddressMode = enum(c_ulong) {
    clamp_to_edge = 0,
    mirror_clamp_to_edge = 1,
    repeat = 2,
    mirror_repeat = 3,
    clamp_to_zero = 4,
    clamp_to_border_color = 5,
};

/// https://developer.apple.com/documentation/metal/mtlblendfactor?language=objc
pub const MTLBlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    dest_color = 6,
    one_minus_dest_color = 7,
    dest_alpha = 8,
    one_minus_dest_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
    source_1_color = 15,
    one_minus_source_1_color = 16,
    source_1_alpha = 17,
    one_minus_source_1_alpha = 18,
};

/// https://developer.apple.com/documentation/metal/mtlblendoperation?language=objc
pub const MTLBlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

/// https://developer.apple.com/documentation/metal/mtltextureusage?language=objc
pub const MTLTextureUsage = packed struct(c_ulong) {
    /// https://developer.apple.com/documentation/metal/mtltextureusage/shaderread?language=objc
    shader_read: bool = false, // TextureUsageShaderRead = 1,

    /// https://developer.apple.com/documentation/metal/mtltextureusage/shaderwrite?language=objc
    shader_write: bool = false, // TextureUsageShaderWrite = 2,

    /// https://developer.apple.com/documentation/metal/mtltextureusage/rendertarget?language=objc
    render_target: bool = false, // TextureUsageRenderTarget = 4,

    _reserved: u1 = 0, // The enum skips from 4 to 16, 8 has no documented use.

    /// https://developer.apple.com/documentation/metal/mtltextureusage/pixelformatview?language=objc
    pixel_format_view: bool = false, // TextureUsagePixelFormatView = 16,

    /// https://developer.apple.com/documentation/metal/mtltextureusage/shaderatomic?language=objc
    shader_atomic: bool = false, // TextureUsageShaderAtomic = 32,

    __reserved: @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = @bitSizeOf(c_ulong) - 6,
    } }) = 0,

    /// https://developer.apple.com/documentation/metal/mtltextureusage/unknown?language=objc
    const unknown: MTLTextureUsage = @bitCast(0); // TextureUsageUnknown = 0,
};

/// https://developer.apple.com/documentation/metal/mtlbarrierscope?language=objc
pub const MTLBarrierScope = enum(c_ulong) {
    buffers = 1,
    textures = 2,
    render_targets = 4,
};

/// https://developer.apple.com/documentation/metal/mtlrenderstages?language=objc
pub const MTLRenderStage = enum(c_ulong) {
    vertex = 1,
    fragment = 2,
    tile = 4,
    object = 8,
    mesh = 16,
};

pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

pub const MTLViewport = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

pub const MTLOrigin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

pub const MTLSize = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

/// https://developer.apple.com/documentation/metal/1433367-mtlcopyalldevices
pub extern "c" fn MTLCopyAllDevices() ?*anyopaque;

/// https://developer.apple.com/documentation/metal/1433401-mtlcreatesystemdefaultdevice
pub extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
