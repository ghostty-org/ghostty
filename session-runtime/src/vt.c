#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <libproc.h>
int omg_process_cwd(int pid, unsigned char *buffer, size_t capacity) {
    struct proc_vnodepathinfo info;
    int result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (result != sizeof(info)) return -1;
    size_t len = strnlen(info.pvi_cdir.vip_path, sizeof(info.pvi_cdir.vip_path));
    if (len >= capacity) return -1;
    memcpy(buffer, info.pvi_cdir.vip_path, len);
    return (int)len;
}
#endif

typedef void (*Reply)(void *, const unsigned char *, size_t);
typedef void (*Context)(void *, bool, const uint8_t *, size_t, const uint8_t *, size_t);
typedef struct {
    GhosttyTerminal terminal;
    Reply reply;
    void *context;
    Context signal;
    void *signal_context;
} Vt;
static void context_signal(GhosttyTerminal terminal, void *context, bool ended,
                           GhosttyString id, GhosttyString metadata) {
    (void)terminal;
    Vt *vt = context;
    if (vt->signal) vt->signal(vt->signal_context, ended,
        (const uint8_t *)id.ptr, id.len, (const uint8_t *)metadata.ptr, metadata.len);
}
int omg_vt_context(Vt *vt, Context callback, void *context) {
    vt->signal = callback;
    vt->signal_context = context;
    return ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CONTEXT_SIGNAL, (const void *)context_signal);
}
static void reply(GhosttyTerminal terminal, void *context, const uint8_t *bytes, size_t len) {
    (void)terminal;
    Vt *vt = context;
    if (vt->reply) vt->reply(vt->context, bytes, len);
}
static int resize_pixels(Vt *vt, unsigned short cols, unsigned short rows,
                         unsigned short pixel_width, unsigned short pixel_height) {
    if (!cols || !rows) return -1;
    unsigned short cell_width = pixel_width / cols;
    unsigned short cell_height = pixel_height / rows;
    if (!cell_width) cell_width = 1;
    if (!cell_height) cell_height = 1;
    return ghostty_terminal_resize(vt->terminal, cols, rows, cell_width, cell_height);
}

void *omg_vt_new_with_pixels_scrollback(unsigned short cols, unsigned short rows,
                                        unsigned short pixel_width, unsigned short pixel_height,
                                        size_t scrollback_max_bytes,
                                        const size_t *scrollback_max_lines,
                                        Reply callback, void *context) {
    Vt *vt = calloc(1, sizeof(*vt));
    if (!vt) return NULL;
    if (ghostty_terminal_new(NULL, &vt->terminal, cols, rows) != GHOSTTY_SUCCESS) { free(vt); return NULL; }
    if (resize_pixels(vt, cols, rows, pixel_width, pixel_height) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(vt->terminal); free(vt); return NULL;
    }
    size_t continuation = 1024 * 1024;
    vt->reply = callback; vt->context = context;
    if (ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_max_bytes) != GHOSTTY_SUCCESS ||
        (scrollback_max_lines && ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, scrollback_max_lines) != GHOSTTY_SUCCESS) ||
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)reply) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(vt->terminal); free(vt); return NULL;
    }
    return vt;
}
int omg_vt_scrollback_limits(Vt *vt, size_t *scrollback_max_bytes,
                             bool *has_scrollback_max_lines,
                             size_t *scrollback_max_lines) {
    int result = ghostty_terminal_get(
        vt->terminal,
        GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,
        scrollback_max_bytes);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_get(
        vt->terminal,
        GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES,
        scrollback_max_lines);
    if (result == GHOSTTY_NO_VALUE) {
        *has_scrollback_max_lines = false;
        return GHOSTTY_SUCCESS;
    }
    if (result != GHOSTTY_SUCCESS) return result;
    *has_scrollback_max_lines = true;
    return GHOSTTY_SUCCESS;
}
void omg_vt_free(Vt *vt) { ghostty_terminal_free(vt->terminal); free(vt); }
void omg_vt_write(Vt *vt, const unsigned char *data, size_t len) { ghostty_terminal_vt_write(vt->terminal, data, len); }
int omg_vt_resize(Vt *vt, unsigned short cols, unsigned short rows) { return ghostty_terminal_resize(vt->terminal, cols, rows, 8, 16); }
int omg_vt_resize_pixels(Vt *vt, unsigned short cols, unsigned short rows,
                         unsigned short pixel_width, unsigned short pixel_height) {
    return resize_pixels(vt, cols, rows, pixel_width, pixel_height);
}
int omg_vt_snapshot(Vt *vt, unsigned char **data, size_t *len) { return ghostty_snapshot_encode_alloc(vt->terminal, NULL, data, len); }
void omg_vt_buffer_free(unsigned char *data, size_t len) { ghostty_free(NULL, data, len); }
int omg_vt_restore(Vt *vt, const unsigned char *data, size_t len) {
    GhosttySnapshotDecoder decoder = NULL;
    GhosttyTerminal terminal = NULL;
    int result = ghostty_snapshot_decoder_new_buf(NULL, &decoder, data, len);
    if (result) return result;
    bool retain = true;
    size_t limit = 1024 * 1024;
    result = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit);
    if (!result) result = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain);
    if (!result) result = ghostty_snapshot_decoder_decode(decoder, &terminal);
    size_t consumed = 0;
    if (!result) result = ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &consumed);
    ghostty_snapshot_decoder_free(decoder);
    if (result || consumed != len) { if (terminal) ghostty_terminal_free(terminal); return result ? result : -1; }
    ghostty_terminal_free(vt->terminal); vt->terminal = terminal;
    result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt);
    if (!result) result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)reply);
    if (!result && vt->signal) result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CONTEXT_SIGNAL, (const void *)context_signal);
    return result;
}
int omg_vt_continuation(Vt *vt, unsigned char **data, size_t *len) {
    return ghostty_terminal_continuation_alloc(vt->terminal, NULL, data, len);
}
int omg_vt_screen_only(Vt *vt) {
    size_t zero = 0;
    int result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &zero);
    if (!result) result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &zero);
    return result;
}
int omg_vt_dynamic_color(Vt *vt, unsigned int index, unsigned char *rgb) {
    const GhosttyTerminalData keys[] = {
        GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
        GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
        GHOSTTY_TERMINAL_DATA_COLOR_CURSOR
    };
    if (index >= 3) return -1;
    GhosttyColorRgb color;
    int result = ghostty_terminal_get(vt->terminal, keys[index], &color);
    if (!result) { rgb[0] = color.r; rgb[1] = color.g; rgb[2] = color.b; }
    return result;
}
int omg_vt_paint(Vt *vt, unsigned char **data, size_t *len, bool *alternate) {
    uint16_t cols = 0, rows = 0;
    GhosttyTerminalScreen screen;
    int result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if (result || !cols || !rows) return result ? result : -1;
    *alternate = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    GhosttySelection selection = {0};
    selection.size = sizeof(selection);
    GhosttyPoint start = {.tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = {.x = 0, .y = 0}};
    GhosttyPoint end = {.tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = {.x = cols - 1, .y = rows - 1}};
    result = ghostty_terminal_grid_ref(vt->terminal, start, &selection.start);
    if (!result) result = ghostty_terminal_grid_ref(vt->terminal, end, &selection.end);
    if (result) return result;
    GhosttyFormatterTerminalOptions opts = {0};
    opts.size = sizeof(opts);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    opts.selection = &selection;
    opts.extra.size = sizeof(opts.extra);
    // Theme defaults belong to the outer viewer, not the headless runtime.
    opts.extra.palette = false;
    opts.extra.modes = opts.extra.scrolling_region = opts.extra.tabstops = true;
    opts.extra.pwd = opts.extra.keyboard = true;
    opts.extra.screen.size = sizeof(opts.extra.screen);
    opts.extra.screen.cursor = opts.extra.screen.style = opts.extra.screen.hyperlink = true;
    opts.extra.screen.protection = opts.extra.screen.kitty_keyboard = opts.extra.screen.charsets = true;
    GhosttyFormatter formatter = NULL;
    result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal, opts);
    if (result) return result;
    result = ghostty_formatter_format_alloc(formatter, NULL, data, len);
    ghostty_formatter_free(formatter);
    return result;
}
int omg_vt_text(Vt *vt, unsigned char **data, size_t *len) {
    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions opts = {0};
    opts.size = sizeof(opts); opts.trim = true;
    int result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal, opts);
    if (result) return result;
    result = ghostty_formatter_format_alloc(formatter, NULL, data, len);
    ghostty_formatter_free(formatter);
    return result;
}
