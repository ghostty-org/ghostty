/**
 * @file sys.h
 *
 * System interface - runtime-swappable implementations for external dependencies.
 */

#ifndef GHOSTTY_VT_SYS_H
#define GHOSTTY_VT_SYS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>

/** @defgroup sys System Interface
 *
 * Runtime-swappable function pointers for operations that depend on
 * external implementations (e.g. image decoding).
 *
 * These are process-global settings that must be configured at startup
 * before any terminal functionality that depends on them is used.
 * Setting these enables various optional features of the terminal. For
 * example, setting a PNG decoder enables PNG image support in the Kitty
 * Graphics Protocol.
 *
 * Use ghostty_sys_set() with a `GhosttySysOption` to install or clear
 * an implementation. Passing NULL as the value clears the implementation
 * and disables the corresponding feature.
 *
 * ## Example
 *
 * ### Defining a PNG decode callback
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-decode-png
 *
 * ### Installing the callback and sending a PNG image
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-main
 *
 * @{
 */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * A decoded image, filled in by a decode callback such as
 * GhosttySysDecodePngFn.
 *
 * Pixels are 8-bit RGBA: four bytes per pixel, stored row by row starting
 * at the top-left corner, with no padding between rows. A complete image
 * is therefore `width * height * 4` bytes long.
 *
 * The pixel buffer must be allocated with the allocator passed to the
 * decode callback. When the callback returns true, the library takes
 * ownership of the buffer and frees it with that same allocator.
 *
 * The allocator requires the allocation length to free, so a decoder that
 * allocates more than it fills must report the surplus in `data_extra`.
 * This lets a decoder over-allocate (round up to a block size, reuse a
 * buffer sized for the largest image it expects, and so on) instead of
 * sizing every allocation exactly.
 */
typedef struct {
    /** Image width in pixels. */
    uint32_t width;

    /** Image height in pixels. */
    uint32_t height;

    /**
     * The decoded RGBA pixels, allocated with the allocator passed to
     * the decode callback.
     */
    uint8_t* data;

    /**
     * Length of the pixel data in bytes. Together with `data_extra`, this
     * must be the exact size that was requested from the allocator,
     * because the library uses it to free the buffer.
     */
    size_t data_len;

    /**
     * Number of bytes allocated beyond `data_len`, when the decoder
     * allocated more than it filled. The library frees the buffer with
     * `data_len + data_extra` bytes.
     *
     * Leave this as 0 when the allocation is exactly `data_len` bytes.
     */
    size_t data_extra;
} GhosttySysImage;

/**
 * Log severity levels for the log callback.
 */
typedef enum GHOSTTY_ENUM_TYPED {
    GHOSTTY_SYS_LOG_LEVEL_ERROR = 0,
    GHOSTTY_SYS_LOG_LEVEL_WARNING = 1,
    GHOSTTY_SYS_LOG_LEVEL_INFO = 2,
    GHOSTTY_SYS_LOG_LEVEL_DEBUG = 3,
    GHOSTTY_SYS_LOG_LEVEL_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySysLogLevel;

/**
 * Callback type for logging.
 *
 * When installed, internal library log messages are delivered through
 * this callback instead of being discarded. The embedder is responsible
 * for formatting and routing log output.
 *
 * @p scope is the log scope name as UTF-8 bytes (e.g. "osc", "kitty").
 * When the log is unscoped (default scope), @p scope_len is 0.
 *
 * All pointer arguments are only valid for the duration of the callback.
 * The callback must be safe to call from any thread.
 *
 * @param userdata    The userdata pointer set via GHOSTTY_SYS_OPT_USERDATA
 * @param level       The severity level of the log message
 * @param scope       Pointer to the scope name bytes
 * @param scope_len   Length of the scope name in bytes
 * @param message     Pointer to the log message bytes
 * @param message_len Length of the log message in bytes
 */
typedef void (*GhosttySysLogFn)(
    void* userdata,
    GhosttySysLogLevel level,
    const uint8_t* scope,
    size_t scope_len,
    const uint8_t* message,
    size_t message_len);

/**
 * Callback type for PNG decoding.
 *
 * The library calls this when it receives a PNG image and needs the raw
 * pixels. The callback decodes the PNG bytes in @p data and describes
 * the result in @p out. See the example in the @ref sys overview for a
 * complete callback.
 *
 * ### On success
 *
 * Allocate the pixel buffer with ghostty_alloc() and @p allocator, write
 * the decoded pixels into it, set `width`, `height`, `data` and `data_len`
 * of @p out, and return true. The library then owns the buffer and frees
 * it with the same allocator. See GhosttySysImage for the expected pixel
 * layout.
 *
 * The allocator limits how much memory a single image may use, so
 * ghostty_alloc() can return NULL for very large images. Treat that as
 * a failure.
 *
 * ### On failure
 *
 * Free anything that was allocated and return false. The library does
 * not read @p out in this case, and the image is rejected.
 *
 * ### The output struct starts zeroed
 *
 * The library sets every field of @p out to zero before it calls the
 * callback. This has two practical effects:
 *
 * - If the callback returns true but `data` is still NULL, the library
 *   treats the call as a failure.
 * - Language bindings can store a pointer into @p out directly. Some
 *   runtimes, such as Go, require memory to be initialized before a
 *   pointer is written into it, and this guarantee satisfies that
 *   requirement.
 *
 * Only @p out is zeroed. Memory returned by ghostty_alloc() is not.
 *
 * @p data and @p allocator are only valid for the duration of the
 * callback.
 *
 * Set `out->data_extra` if the allocation is larger than the pixel data,
 * otherwise leave it at 0. See GhosttySysImage.
 *
 * @param userdata  The userdata pointer set via GHOSTTY_SYS_OPT_USERDATA
 * @param allocator The allocator to use for the output pixel buffer
 * @param data      Pointer to the raw PNG data
 * @param data_len  Length of the raw PNG data in bytes
 * @param[out] out  The decoded image. Zeroed by the library before the
 *                  call, and filled in by the callback on success.
 * @return true if the image was decoded and @p out was filled in,
 *         false on failure
 */
typedef bool (*GhosttySysDecodePngFn)(
    void* userdata,
    const GhosttyAllocator* allocator,
    const uint8_t* data,
    size_t data_len,
    GhosttySysImage* out);

/**
 * Callback type for secure random bytes.
 *
 * Fills @p buf with @p len cryptographically secure random bytes. The
 * library uses this for secrets, so it must be a real CSPRNG (getrandom,
 * arc4random_buf, BCryptGenRandom, crypto.getRandomValues, ...); a
 * predictable source is a security hole.
 *
 * @param userdata The userdata pointer set via GHOSTTY_SYS_OPT_USERDATA
 * @param buf      Buffer to fill
 * @param len      Number of bytes to fill
 * @return true if the buffer was filled, false if no entropy is available
 */
typedef bool (*GhosttySysRandomSecureFn)(
    void* userdata,
    uint8_t* buf,
    size_t len);

/**
 * System option identifiers for ghostty_sys_set().
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /**
     * Set the userdata pointer passed to all sys callbacks.
     *
     * Input type: void* (or NULL)
     */
    GHOSTTY_SYS_OPT_USERDATA = 0,

    /**
     * Set the PNG decode function.
     *
     * When set, the terminal can accept PNG images via the Kitty
     * Graphics Protocol. When cleared (NULL value), PNG decoding is
     * unsupported and PNG image data will be rejected.
     *
     * Input type: GhosttySysDecodePngFn (function pointer, or NULL)
     */
    GHOSTTY_SYS_OPT_DECODE_PNG = 1,

    /**
     * Set the log callback.
     *
     * When set, internal library log messages are delivered to this
     * callback. When cleared (NULL value), log messages are silently
     * discarded.
     *
     * Use ghostty_sys_log_stderr as a convenience callback that
     * writes formatted messages to stderr.
     *
     * Which log levels are emitted depends on the build mode of the
     * library and is not configurable at runtime. Debug builds emit
     * all levels (debug and above). Release builds emit info and
     * above; debug-level messages are compiled out entirely and will
     * never reach the callback.
     *
     * Input type: GhosttySysLogFn (function pointer, or NULL)
     */
    GHOSTTY_SYS_OPT_LOG = 2,

    /**
     * Override the secure random source.
     *
     * By default the library draws secure random bytes from the
     * platform (getrandom or arc4random_buf on POSIX, CNG on Windows).
     * Targets without one, such as wasm32-freestanding, have no default
     * and operations that need entropy fail with GHOSTTY_IO_ERROR until
     * this is set. When set,
     * it is used instead of the platform source on every target. When
     * cleared (NULL value), the platform default is restored.
     *
     * Input type: GhosttySysRandomSecureFn (function pointer, or NULL)
     */
    GHOSTTY_SYS_OPT_RANDOM_SECURE = 3,
    GHOSTTY_SYS_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySysOption;

/**
 * Set a system-level option.
 *
 * Configures a process-global implementation function. These should be
 * set once at startup before using any terminal functionality that
 * depends on them.
 *
 * @param option The option to set
 * @param value  Pointer to the value (type depends on the option),
 *               or NULL to clear it
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the
 *         option is not recognized
 */
GHOSTTY_API GhosttyResult ghostty_sys_set(GhosttySysOption option,
                                           const void* value);

/**
 * Built-in log callback that writes to stderr.
 *
 * Formats each message as "[level](scope): message\n".
 * Can be passed directly to ghostty_sys_set():
 *
 * @code
 * ghostty_sys_set(GHOSTTY_SYS_OPT_LOG, &ghostty_sys_log_stderr);
 * @endcode
 */
GHOSTTY_API void ghostty_sys_log_stderr(void* userdata,
                                         GhosttySysLogLevel level,
                                         const uint8_t* scope,
                                         size_t scope_len,
                                         const uint8_t* message,
                                         size_t message_len);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_SYS_H */
