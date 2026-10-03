/**
 * @file osc.h
 *
 * OSC (Operating System Command) sequence parser and command handling.
 */

#ifndef GHOSTTY_VT_OSC_H
#define GHOSTTY_VT_OSC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>

/** @defgroup osc OSC Parser
 *
 * OSC (Operating System Command) sequence parser and command handling.
 *
 * The parser operates in a streaming fashion, processing input byte-by-byte
 * to handle OSC sequences that may arrive in fragments across multiple reads.
 * This interface makes it easy to integrate into most environments and avoids
 * over-allocating buffers.
 *
 * ## Basic Usage
 *
 * 1. Create a parser instance with ghostty_osc_new()
 * 2. Feed bytes to the parser using ghostty_osc_next() 
 * 3. Finalize parsing with ghostty_osc_end() to get the command
 * 4. Query command type and extract data using ghostty_osc_command_type()
 *    and ghostty_osc_command_data()
 * 5. Call ghostty_osc_reset() before parsing the next sequence
 * 6. Free the parser with ghostty_osc_free() when done
 *
 * ## Ending a Sequence
 *
 * An OSC sequence normally ends with BEL (0x07) or ST (ESC followed by a
 * backslash). A program can also cancel a sequence partway through by
 * sending CAN (0x18) or SUB (0x1A) instead. A cancelled sequence has no
 * effect, even if the bytes before the cancel form a complete command.
 *
 * In every case, pass the byte that ended the sequence to
 * ghostty_osc_end(). For CAN or SUB, it discards the sequence and returns
 * NULL:
 *
 * @code{.c}
 * // The program sent "ESC ] 2 ; hello" to set the window title, then
 * // sent CAN instead of a terminator.
 * const char* input = "2;hello";
 * for (size_t i = 0; input[i] != '\0'; i++) {
 *   ghostty_osc_next(parser, (uint8_t)input[i]);
 * }
 *
 * GhosttyOscCommand command = ghostty_osc_end(parser, 0x18);
 * // command is NULL, so the window title does not change.
 *
 * ghostty_osc_reset(parser);
 * @endcode
 *
 * ## Unknown Commands
 *
 * Every OSC sequence starts with a number that says what it is, such as
 * 2 for the window title or 8 for a hyperlink. By default, a sequence whose
 * number the parser does not implement produces
 * GHOSTTY_OSC_COMMAND_INVALID, and its data is discarded.
 *
 * To implement such a sequence yourself, set
 * GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES with ghostty_osc_set(). The parser
 * then produces GHOSTTY_OSC_COMMAND_UNKNOWN for these sequences, and you
 * can read the raw sequence with GHOSTTY_OSC_DATA_UNKNOWN_CONTENT.
 *
 * @code{.c}
 * GhosttyOscParser parser;
 * ghostty_osc_new(NULL, &parser);
 *
 * // Keep up to 1 KiB of each unknown sequence.
 * size_t max_bytes = 1024;
 * ghostty_osc_set(parser, GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES, &max_bytes);
 *
 * // Feed the bytes between ESC ] and the terminator. OSC 7400 is made up
 * // for this example, so the parser does not implement it.
 * const char* input = "7400;status=busy";
 * for (size_t i = 0; input[i] != '\0'; i++) {
 *   ghostty_osc_next(parser, (uint8_t)input[i]);
 * }
 *
 * // This sequence ended with BEL (0x07).
 * GhosttyOscCommand command = ghostty_osc_end(parser, 0x07);
 * if (ghostty_osc_command_type(command) == GHOSTTY_OSC_COMMAND_UNKNOWN) {
 *   GhosttyString content;
 *   ghostty_osc_command_data(command, GHOSTTY_OSC_DATA_UNKNOWN_CONTENT,
 *                            &content);
 *   // content now holds "7400;status=busy".
 * }
 *
 * ghostty_osc_free(parser);
 * @endcode
 *
 * Only numbers the parser does not implement are reported this way. A
 * sequence with a number the parser does implement stays
 * GHOSTTY_OSC_COMMAND_INVALID when its contents are malformed.
 *
 * @{
 */

/**
 * OSC command types.
 *
 * @ingroup osc
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_OSC_COMMAND_INVALID = 0,
  GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE = 1,
  GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON = 2,
  GHOSTTY_OSC_COMMAND_SEMANTIC_PROMPT = 3,
  GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS = 4,
  GHOSTTY_OSC_COMMAND_REPORT_PWD = 5,
  GHOSTTY_OSC_COMMAND_MOUSE_SHAPE = 6,
  GHOSTTY_OSC_COMMAND_COLOR_OPERATION = 7,
  GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL = 8,
  GHOSTTY_OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION = 9,
  GHOSTTY_OSC_COMMAND_HYPERLINK_START = 10,
  GHOSTTY_OSC_COMMAND_HYPERLINK_END = 11,
  GHOSTTY_OSC_COMMAND_CONEMU_SLEEP = 12,
  GHOSTTY_OSC_COMMAND_CONEMU_SHOW_MESSAGE_BOX = 13,
  GHOSTTY_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE = 14,
  GHOSTTY_OSC_COMMAND_CONEMU_PROGRESS_REPORT = 15,
  GHOSTTY_OSC_COMMAND_CONEMU_WAIT_INPUT = 16,
  GHOSTTY_OSC_COMMAND_CONEMU_GUIMACRO = 17,
  GHOSTTY_OSC_COMMAND_CONEMU_RUN_PROCESS = 18,
  GHOSTTY_OSC_COMMAND_CONEMU_OUTPUT_ENVIRONMENT_VARIABLE = 19,
  GHOSTTY_OSC_COMMAND_CONEMU_XTERM_EMULATION = 20,
  GHOSTTY_OSC_COMMAND_CONEMU_COMMENT = 21,
  GHOSTTY_OSC_COMMAND_KITTY_TEXT_SIZING = 22,
  GHOSTTY_OSC_COMMAND_KITTY_CLIPBOARD_PROTOCOL = 23,
  GHOSTTY_OSC_COMMAND_KITTY_DND_PROTOCOL = 24,
  GHOSTTY_OSC_COMMAND_CONTEXT_SIGNAL = 25,
  GHOSTTY_OSC_COMMAND_KITTY_DESKTOP_NOTIFICATION = 26,

  /**
   * An OSC sequence whose number the parser does not implement. Read it
   * with the GHOSTTY_OSC_DATA_UNKNOWN_* data types.
   *
   * Only produced when GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES is nonzero.
   * Otherwise these sequences are GHOSTTY_OSC_COMMAND_INVALID.
   */
  GHOSTTY_OSC_COMMAND_UNKNOWN = 27,
  GHOSTTY_OSC_COMMAND_TYPE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyOscCommandType;

/**
 * How an OSC sequence was ended.
 *
 * Programs can end an OSC sequence in two ways. When you reply to a
 * sequence, end the reply the same way the program ended its request.
 * Some programs only recognize replies that match.
 *
 * @ingroup osc
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The string terminator (ST): ESC followed by a backslash (0x1B 0x5C). */
  GHOSTTY_OSC_TERMINATOR_ST = 0,

  /** The bell character, BEL (byte 0x07). */
  GHOSTTY_OSC_TERMINATOR_BEL = 1,
  GHOSTTY_OSC_TERMINATOR_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyOscTerminator;

/**
 * OSC parser options, set with ghostty_osc_set().
 *
 * @ingroup osc
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * The most bytes to keep from each OSC sequence whose number the parser
   * does not implement.
   *
   * Zero, the default, discards these sequences and they produce
   * GHOSTTY_OSC_COMMAND_INVALID. Any other value makes them produce
   * GHOSTTY_OSC_COMMAND_UNKNOWN. A NULL value pointer sets the limit back
   * to zero.
   *
   * A sequence longer than the limit is still reported. Its content holds
   * the first bytes up to the limit, and GHOSTTY_OSC_DATA_UNKNOWN_TRUNCATED
   * is true.
   *
   * Limits up to 2048 bytes use a buffer the parser already owns and never
   * allocate memory. Larger limits allocate memory from the parser's
   * allocator for each unknown sequence.
   *
   * Input type: size_t*
   */
  GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES = 0,
  GHOSTTY_OSC_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyOscOption;

/**
 * OSC command data types.
 * 
 * These values specify what type of data to extract from an OSC command
 * using `ghostty_osc_command_data`.
 *
 * @ingroup osc
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_OSC_DATA_INVALID = 0,
  
  /** 
   * Window title string data.
   *
   * Valid for: GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE
   *
   * Output type: const char ** (pointer to null-terminated string)
   *
   * Lifetime: Valid until the next call to any ghostty_osc_* function with 
   * the same parser instance. Memory is owned by the parser.
   */
  GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR = 1,

  /**
   * The raw bytes of an unknown sequence: everything that was passed to
   * ghostty_osc_next(), including the number at the start. For example,
   * the sequence `ESC ] 7400;status=busy BEL` gives
   * `7400;status=busy`. The bytes are not null-terminated.
   *
   * Valid for: GHOSTTY_OSC_COMMAND_UNKNOWN
   *
   * Output type: GhosttyString *
   *
   * Lifetime: Valid until the next call to any ghostty_osc_* function with
   * the same parser instance. Memory is owned by the parser.
   */
  GHOSTTY_OSC_DATA_UNKNOWN_CONTENT = 2,

  /**
   * True if the unknown sequence was longer than
   * GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES, or memory ran out while reading it.
   * In that case the content holds only the beginning of the sequence.
   *
   * Valid for: GHOSTTY_OSC_COMMAND_UNKNOWN
   *
   * Output type: bool *
   */
  GHOSTTY_OSC_DATA_UNKNOWN_TRUNCATED = 3,

  /**
   * How the unknown sequence was ended, based on the terminator passed to
   * ghostty_osc_end(). If you reply to the sequence, end the reply the same
   * way.
   *
   * Valid for: GHOSTTY_OSC_COMMAND_UNKNOWN
   *
   * Output type: GhosttyOscTerminator *
   */
  GHOSTTY_OSC_DATA_UNKNOWN_TERMINATOR = 4,
  GHOSTTY_OSC_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyOscCommandData;

/**
 * Create a new OSC parser instance.
 * 
 * Creates a new OSC (Operating System Command) parser using the provided
 * allocator. The parser must be freed using ghostty_vt_osc_free() when
 * no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param parser Pointer to store the created parser handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 * 
 * @ingroup osc
 */
GHOSTTY_API GhosttyResult ghostty_osc_new(const GhosttyAllocator *allocator, GhosttyOscParser *parser);

/**
 * Free an OSC parser instance.
 * 
 * Releases all resources associated with the OSC parser. After this call,
 * the parser handle becomes invalid and must not be used.
 * 
 * @param parser The parser handle to free (may be NULL)
 * 
 * @ingroup osc
 */
GHOSTTY_API void ghostty_osc_free(GhosttyOscParser parser);

/**
 * Reset an OSC parser instance to its initial state.
 * 
 * Resets the parser state, clearing any partially parsed OSC sequences
 * and returning the parser to its initial state. This is useful for
 * reusing a parser instance or recovering from parse errors.
 * 
 * @param parser The parser handle to reset, must not be null.
 * 
 * @ingroup osc
 */
GHOSTTY_API void ghostty_osc_reset(GhosttyOscParser parser);

/**
 * Set an option on an OSC parser.
 *
 * `value` points to the option's input type, which is listed in the
 * documentation for each GhosttyOscOption value. Pass NULL to restore the
 * option's default.
 *
 * Options stay set across ghostty_osc_reset(). You can change an option
 * at any time, but a sequence that is already being parsed may keep the
 * old setting. It is simplest to set options before the first sequence.
 *
 * @param parser The parser handle
 * @param option The option to set
 * @param value Pointer to the new value, or NULL to restore the default
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if the parser
 *         is NULL
 *
 * @ingroup osc
 */
GHOSTTY_API GhosttyResult ghostty_osc_set(GhosttyOscParser parser,
                                          GhosttyOscOption option,
                                          const void* value);

/**
 * Parse the next byte in an OSC sequence.
 * 
 * Processes a single byte as part of an OSC sequence. The parser maintains
 * internal state to track the progress through the sequence. Call this
 * function for each byte in the sequence data.
 *
 * When finished pumping the parser with bytes, call ghostty_osc_end
 * to get the final result.
 * 
 * @param parser The parser handle, must not be null.
 * @param byte The next byte to parse
 * 
 * @ingroup osc
 */
GHOSTTY_API void ghostty_osc_next(GhosttyOscParser parser, uint8_t byte);

/**
 * Finalize OSC parsing and retrieve the parsed command.
 * 
 * Call this after feeding every byte of the sequence to ghostty_osc_next(),
 * except the byte that ended it. Pass that byte here as the terminator.
 *
 * If the sequence is not a valid command, this returns NULL. You don't need
 * to check for NULL before calling ghostty_osc_command_type(), which
 * returns GHOSTTY_OSC_COMMAND_INVALID for it.
 *
 * Commands that reply to the program, such as color queries, end their
 * reply the same way the request ended. A terminator of 0x07 (BEL) gets a
 * BEL reply, and any other byte gets an ST reply. Commands that don't
 * reply ignore the terminator.
 *
 * If the program cancelled the sequence with CAN (0x18) or SUB (0x1A),
 * pass that byte as the terminator. The sequence is then discarded and
 * this returns NULL, whatever command it contained. This matches xterm.
 * The "Ending a Sequence" section of the overview has an example.
 * 
 * The returned command handle is valid until the next call to any 
 * `ghostty_osc_*` function with the same parser instance with the exception
 * of command introspection functions such as `ghostty_osc_command_type`.
 * 
 * @param parser The parser handle, must not be null.
 * @param terminator The byte that ended the OSC sequence: 0x07 for BEL,
 *        0x5C for ST, or 0x18 (CAN) or 0x1A (SUB) if it was cancelled
 * @return Handle to the parsed OSC command, or NULL if the sequence is not
 *         a valid command or was cancelled
 * 
 * @ingroup osc
 */
GHOSTTY_API GhosttyOscCommand ghostty_osc_end(GhosttyOscParser parser, uint8_t terminator);

/**
 * Get the type of an OSC command.
 * 
 * Returns the type identifier for the given OSC command. This can be used
 * to determine what kind of command was parsed and what data might be
 * available from it.
 * 
 * @param command The OSC command handle to query (may be NULL)
 * @return The command type, or GHOSTTY_OSC_COMMAND_INVALID if command is NULL
 * 
 * @ingroup osc
 */
GHOSTTY_API GhosttyOscCommandType ghostty_osc_command_type(GhosttyOscCommand command);

/**
 * Extract data from an OSC command.
 * 
 * Extracts typed data from the given OSC command based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid command types, output types, and memory
 * safety information are documented in the `GhosttyOscCommandData` enum.
 *
 * @param command The OSC command handle to query (may be NULL)
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return true if data extraction was successful, false otherwise
 * 
 * @ingroup osc
 */
GHOSTTY_API bool ghostty_osc_command_data(GhosttyOscCommand command, GhosttyOscCommandData data, void *out);

/** @} */

#endif /* GHOSTTY_VT_OSC_H */
