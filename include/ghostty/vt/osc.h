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
#include <ghostty/vt/result.h>
#include <ghostty/vt/allocator.h>

/**
 * Opaque handle to an OSC parser instance.
 * 
 * This handle represents an OSC (Operating System Command) parser that can
 * be used to parse the contents of OSC sequences.
 *
 * @ingroup osc
 */
typedef struct GhosttyOscParser *GhosttyOscParser;

/**
 * Opaque handle to a single OSC command.
 * 
 * This handle represents a parsed OSC (Operating System Command) command.
 * The command can be queried for its type and associated data.
 *
 * @ingroup osc
 */
typedef struct GhosttyOscCommand *GhosttyOscCommand;

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
 * 5. Free the parser with ghostty_osc_free() when done
 *
 * @{
 */

/**
 * OSC command types.
 *
 * @ingroup osc
 */
typedef enum {
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
} GhosttyOscCommandType;

/**
 * OSC command data types.
 * 
 * These values specify what type of data to extract from an OSC command
 * using `ghostty_osc_command_data`.
 *
 * @ingroup osc
 */
typedef enum {
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
GhosttyResult ghostty_osc_new(const GhosttyAllocator *allocator, GhosttyOscParser *parser);

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
void ghostty_osc_free(GhosttyOscParser parser);

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
void ghostty_osc_reset(GhosttyOscParser parser);

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
void ghostty_osc_next(GhosttyOscParser parser, uint8_t byte);

/**
 * Finalize OSC parsing and retrieve the parsed command.
 * 
 * Call this function after feeding all bytes of an OSC sequence to the parser
 * using ghostty_osc_next() with the exception of the terminating character
 * (ESC or ST). This function finalizes the parsing process and returns the 
 * parsed OSC command.
 *
 * The return value is never NULL. Invalid commands will return a command
 * with type GHOSTTY_OSC_COMMAND_INVALID.
 * 
 * The terminator parameter specifies the byte that terminated the OSC sequence
 * (typically 0x07 for BEL or 0x5C for ST after ESC). This information is
 * preserved in the parsed command so that responses can use the same terminator
 * format for better compatibility with the calling program. For commands that
 * do not require a response, this parameter is ignored and the resulting
 * command will not retain the terminator information.
 * 
 * The returned command handle is valid until the next call to any 
 * `ghostty_osc_*` function with the same parser instance with the exception
 * of command introspection functions such as `ghostty_osc_command_type`.
 * 
 * @param parser The parser handle, must not be null.
 * @param terminator The terminating byte of the OSC sequence (0x07 for BEL, 0x5C for ST)
 * @return Handle to the parsed OSC command
 * 
 * @ingroup osc
 */
GhosttyOscCommand ghostty_osc_end(GhosttyOscParser parser, uint8_t terminator);

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
GhosttyOscCommandType ghostty_osc_command_type(GhosttyOscCommand command);

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
bool ghostty_osc_command_data(GhosttyOscCommand command, GhosttyOscCommandData data, void *out);

/** @} */

#endif /* GHOSTTY_VT_OSC_H */
