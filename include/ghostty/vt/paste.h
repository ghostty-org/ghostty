/**
 * @file paste.h
 *
 * Paste - paste into a terminal, and validate and encode paste data.
 */

#ifndef GHOSTTY_VT_PASTE_H
#define GHOSTTY_VT_PASTE_H

/** @addtogroup paste
 *
 * Paste into a terminal with ghostty_terminal_paste(), or validate and encode
 * paste data without one.
 *
 * What a paste writes depends on the terminal's modes, and
 * ghostty_terminal_paste() reads them itself. If you have a terminal, that's
 * the function you want.
 *
 * ## Example
 *
 * @snippet c-vt-paste/src/main.c terminal-paste
 *
 * Full program: @ref c-vt-paste/src/main.c
 *
 * The @ref guide-input "Input guide" covers what a paste writes and how unsafe
 * pastes are refused.
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/io.h>
#include <ghostty/vt/terminal.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Why a paste happened.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The user pasted from a clipboard: keybind, menu, middle click. */
  GHOSTTY_PASTE_SOURCE_CLIPBOARD = 0,

  /**
   * Text inserted some other way: IME commit, drag and drop, scripted
   * input. Always written as text, never as a paste event, matching
   * kitty. This is not a way to opt out of paste events; an embedder
   * that doesn't want them doesn't install a clipboard_read callback.
   */
  GHOSTTY_PASTE_SOURCE_TEXT = 1,
  GHOSTTY_PASTE_SOURCE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyPasteSource;

/**
 * A paste of clipboard contents into the terminal.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED(), then set
 * the fields you need. See @ref sized-structs.
 *
 * The MIME type array and the strings it points to are borrowed only for
 * the duration of the ghostty_terminal_paste() call, as is everything
 * the reader produces.
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /**
   * The clipboard the contents came from. Reported to the program on a
   * paste event (the selection and primary locations are both reported
   * as the primary selection, the protocol knows only two); no effect
   * on a text paste.
   */
  GhosttyClipboardLocation location;

  /** Why this paste happened. */
  GhosttyPasteSource source;

  /**
   * Borrowed array of the MIME types of the representations available,
   * in preferred order. A text paste reads and writes the first entry
   * with a text MIME type such as "text/plain" and ignores the rest. A
   * paste event lists every entry and reads none. May be NULL when
   * mimes_len is zero, which is nothing to paste.
   */
  const GhosttyString* mimes;

  /** Number of entries in mimes. */
  size_t mimes_len;

  /**
   * Produces the data of a representation on demand. Required when
   * mimes_len is nonzero.
   *
   * Called at most once per ghostty_terminal_paste() call: for the
   * text representation being pasted, never for anything else and
   * never for a paste event. The MIME type requested is always an
   * entry of `mimes`, passed through exactly as given there (the same
   * pointer and length), so the callback may identify the
   * representation by pointer or by content. A false return fails the
   * paste with GHOSTTY_IO_ERROR.
   */
  GhosttyMimeReader reader;

  /**
   * Write text that could inject commands. Call with false, confirm
   * with the person using your terminal on GHOSTTY_REJECTED, and call again with true.
   */
  bool allow_unsafe;
} GhosttyPaste;

/**
 * Paste into the terminal according to its current state: a Kitty
 * clipboard protocol paste event if mode 5522 is enabled and a
 * clipboard_read callback is installed, otherwise the text framed per
 * mode 2004. See @ref guide-input-paste for the full behavior. Output
 * streams through the write_pty callback in chunks. The viewport is not
 * scrolled; that is up to you, as for key input.
 *
 * A paste event records a session grant for its one-time password only
 * once the event is written; a failed call never leaves a grant for an
 * event that was never sent.
 *
 * @param terminal The terminal handle
 * @param paste The paste request, borrowed for the duration of the call
 * @param[out] out_pasted On success, whether anything was written to
 *             the pty (the encoded text or a paste event). False means
 *             there was nothing to paste: no non-empty text
 *             representation. May be NULL.
 * @return GHOSTTY_SUCCESS on success (see @p out_pasted).
 *         GHOSTTY_REJECTED if the text could inject commands and
 *         GhosttyPaste::allow_unsafe is false.
 *         GHOSTTY_INVALID_VALUE for a NULL terminal or paste, an unknown
 *         GhosttyPaste::source, MIME types without a reader, or when no
 *         write_pty callback is installed.
 *         GHOSTTY_OUT_OF_MEMORY if an allocation fails.
 *         GHOSTTY_IO_ERROR if the reader failed or there is no secure
 *         entropy source to create a paste event password
 *         (wasm32-freestanding without GHOSTTY_SYS_OPT_RANDOM_SECURE set).
 *         Errors write nothing.
 */
GHOSTTY_API GhosttyResult ghostty_terminal_paste(
    GhosttyTerminal terminal,
    const GhosttyPaste* paste,
    bool* out_pasted);

/**
 * Check if paste data is safe to paste into the terminal.
 *
 * Data is considered unsafe if it contains:
 * - Line terminators (`\n` or `\r`) which can inject commands. A
 *   carriage return is what the Enter key sends, so it is as dangerous
 *   as a newline on an unbracketed paste.
 * - The bracketed paste end sequence (`\x1b[201~`) which can be used
 *   to exit bracketed paste mode and inject commands
 *
 * This check is conservative and considers data unsafe regardless of
 * current terminal state. ghostty_terminal_paste() applies the
 * terminal-state-aware rule itself (line terminators are safe inside a
 * bracketed paste); use this to apply the stricter rule on top.
 *
 * @param data The paste data to check (NULL is the same as empty data)
 * @param len The length of the data in bytes
 * @return true if the data is safe to paste, false otherwise
 */
GHOSTTY_API bool ghostty_paste_is_safe(const char* data, size_t len);

/**
 * Encode paste data for writing to the terminal pty.
 *
 * This function prepares paste data for terminal input by:
 * - Stripping unsafe control bytes (NUL, ESC, DEL, etc.) by replacing
 *   them with spaces
 * - Wrapping the data in bracketed paste sequences if @p bracketed is true
 * - Replacing newlines with carriage returns if @p bracketed is false
 *
 * The input @p data buffer is modified in place during encoding. The
 * encoded result (potentially with bracketed paste prefix/suffix) is
 * written to the output buffer.
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE, sets
 * @p out_written to the size needed, and leaves @p buf unchanged. To get
 * the size first, pass NULL for @p buf and 0 for @p buf_len. An empty
 * result needs no space, so empty input with @p bracketed false returns
 * GHOSTTY_SUCCESS with @p out_written set to 0.
 *
 * The function modifies @p data even when it returns GHOSTTY_OUT_OF_SPACE.
 * Encoding the modified data again gives the same result, so you can retry
 * with the same @p data and a larger buffer:
 *
 * @code{.c}
 * size_t needed = 0;
 * GhosttyResult result = ghostty_paste_encode(data, data_len, bracketed,
 *                                             NULL, 0, &needed);
 * if (result == GHOSTTY_OUT_OF_SPACE) {
 *   uint8_t *buf = malloc(needed);
 *   size_t written = 0;
 *   result = ghostty_paste_encode(data, data_len, bracketed, buf, needed,
 *                                 &written);
 *   if (result == GHOSTTY_SUCCESS) write(pty_fd, buf, written);
 *   free(buf);
 * }
 * @endcode
 *
 * This is the encoder ghostty_terminal_paste() uses for a text paste;
 * use it directly when there is no terminal to paste into.
 *
 * @param data The paste data to encode (modified in place, may be NULL)
 * @param data_len The length of the input data in bytes
 * @param bracketed Whether bracketed paste mode is active
 * @param buf Buffer to write the encoded result into. May be NULL if
 *            @p buf_len is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small, or GHOSTTY_INVALID_VALUE if @p out_written is NULL
 */
GHOSTTY_API GhosttyResult ghostty_paste_encode(
    char* data,
    size_t data_len,
    bool bracketed,
    uint8_t* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_PASTE_H */
