// For STBI we only need PNG because the only use case we have right now
// is the Kitty Graphics protocol which only supports PNG as a format
// besides raw RGB/RGBA buffers.
#define STBI_ONLY_PNG

// We don't want to support super large images.
#define STBI_MAX_DIMENSIONS 131072

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include <stb_image_resize.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>
