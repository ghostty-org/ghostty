const c = @import("stb_c");

// We'll just add the exports of the functions or types we actually use
// here, no need to export everything from the C lib if we don't use it.
pub const stbi_load_from_memory = c.stbi_load_from_memory;
pub const stbi_image_free = c.stbi_image_free;
pub const stbir_resize_uint8 = c.stbir_resize_uint8;
