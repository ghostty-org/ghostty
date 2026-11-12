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

/** @addtogroup sys
 *
 * The system interface is a set of process-global function pointers for things
 * the library can't do by itself, such as decoding a PNG.
 *
 * Setting one enables the feature that depends on it. For example, setting a
 * PNG decoder enables PNG image support in the Kitty Graphics Protocol. Set
 * them at startup with ghostty_sys_set() and a `GhosttySysOption`. It is not
 * thread-safe, so call it before any other thread uses the library, never while
 * one does. Passing NULL clears an implementation and disables the feature.
 *
 * ## Example
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-decode-png
 *
 * Full program: @ref c-vt-kitty-graphics/src/main.c
 *
 * See @ref guide-images-png for how to write a PNG decoder.
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
     * Length of `data` in bytes. This must be the exact size that was
     * requested from the allocator, because the library uses it to free
     * the buffer.
     */
    size_t data_len;
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
 * this callback instead of being discarded. You are responsible
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
 * the decoded pixels into it, set `width`, `height`, `data` and
 * `data_len` in @p out, and return true. The library then owns the
 * buffer and frees it with the same allocator. See GhosttySysImage for
 * the expected pixel layout.
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
 * callback, so any field the callback does not write reads as zero.
 * This has two practical effects:
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
 * ### The output struct never changes
 *
 * GhosttySysImage is frozen. If a later version of libghostty-vt needs
 * more fields, it adds a new callback typedef and a new option key, and
 * keeps calling this callback with GhosttySysImage forever. A callback
 * written against this header keeps working with every later version of
 * the library.
 *
 * @p data and @p allocator are only valid for the duration of the
 * callback.
 *
 * Use @p allocator only through ghostty_alloc() and ghostty_free().
 * Dereferencing its vtable is not supported.
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
     * Not a real option. ghostty_sys_set() returns GHOSTTY_INVALID_VALUE for
     * it. Its value is 0, so a zeroed or uninitialized variable is never
     * mistaken for a real option.
     */
    GHOSTTY_SYS_OPT_INVALID = 0,

    /**
     * Set the userdata pointer passed to all sys callbacks.
     *
     * Input type: void* (or NULL)
     */
    GHOSTTY_SYS_OPT_USERDATA = 1,

    /**
     * Set the PNG decode function.
     *
     * When set, the terminal can accept PNG images via the Kitty
     * Graphics Protocol. When cleared (NULL value), PNG decoding is
     * unsupported and PNG image data will be rejected.
     *
     * Input type: GhosttySysDecodePngFn (function pointer, or NULL)
     */
    GHOSTTY_SYS_OPT_DECODE_PNG = 2,

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
    GHOSTTY_SYS_OPT_LOG = 3,

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
    GHOSTTY_SYS_OPT_RANDOM_SECURE = 4,
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
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_UNSUPPORTED if the
 *         option is not known to this build (see GhosttyResult)
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
