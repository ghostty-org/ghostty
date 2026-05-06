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
 * Result of decoding an image.
 *
 * The `data` buffer must be allocated through the allocator provided to
 * the decode callback. The library takes ownership and will free it
 * with the same allocator.
 */
typedef struct {
    /** Image width in pixels. */
    uint32_t width;

    /** Image height in pixels. */
    uint32_t height;

    /** Pointer to the decoded RGBA pixel data. */
    uint8_t* data;

    /** Length of the pixel data in bytes. */
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
 * Decodes raw PNG data into RGBA pixels. The output pixel data must be
 * allocated through the provided allocator. The library takes ownership
 * of the buffer and will free it with the same allocator.
 *
 * @param userdata  The userdata pointer set via GHOSTTY_SYS_OPT_USERDATA
 * @param allocator The allocator to use for the output pixel buffer
 * @param data      Pointer to the raw PNG data
 * @param data_len  Length of the raw PNG data in bytes
 * @param[out] out  On success, filled with the decoded image
 * @return true on success, false on failure
 */
typedef bool (*GhosttySysDecodePngFn)(
    void* userdata,
    const GhosttyAllocator* allocator,
    const uint8_t* data,
    size_t data_len,
    GhosttySysImage* out);

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
