const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const fltMax = c.igGET_FLT_MAX;
pub const fltMin = c.igGET_FLT_MIN;
pub const newFrame = c.igNewFrame;
pub const endFrame = c.igEndFrame;
pub const getTextLineHeight = c.igGetTextLineHeight;
pub const render = c.igRender;
pub const end = c.igEnd;
pub const endTable = c.igEndTable;
pub const beginTooltip = c.igBeginTooltip;
pub const endTooltip = c.igEndTooltip;
pub const spacing = c.igSpacing;
pub const text = c.igText;
pub const textDisabled = c.igTextDisabled;
pub const textWrapped = c.igTextWrapped;
pub const button = c.igButton;
pub const sameLine = c.igSameLine;
pub const getFontSize = c.igGetFontSize;
pub const pushTextWrapPos = c.igPushTextWrapPos;
pub const popTextWrapPos = c.igPopTextWrapPos;
pub const treePop = c.igTreePop;
pub const tableHeadersRow = c.igTableHeadersRow;
pub const tableNextColumn = c.igTableNextColumn;

pub fn showDemoWindow(open: ?*bool) void {
    c.igShowDemoWindow(@ptrCast(if (open) |v| v else null));
}

pub fn begin(name: [:0]const u8, open: ?*bool, flags: WindowFlags) bool {
    return c.igBegin(
        name.ptr,
        @ptrCast(if (open) |v| v else null),
        @bitCast(flags),
    );
}

pub fn collapsingHeader(
    label: [:0]const u8,
    visible: ?*bool,
    flags: TreeNodeFlags,
) bool {
    return c.igCollapsingHeader_BoolPtr(
        label.ptr,
        @ptrCast(if (visible) |v| v else null),
        @bitCast(flags),
    );
}

pub fn isItemHovered(flags: HoveredFlags) bool {
    return c.igIsItemHovered(
        @bitCast(flags),
    );
}

pub fn treeNode(
    label: [:0]const u8,
    flags: TreeNodeFlags,
) bool {
    return c.igTreeNodeEx_Str(
        label.ptr,
        @bitCast(flags),
    );
}

pub fn beginTable(
    id: [:0]const u8,
    cols: c_int,
    flags: TableFlags,
) bool {
    return c.igBeginTable(
        id.ptr,
        cols,
        @bitCast(flags),
        .{ .x = 0, .y = 0 },
        0,
    );
}

pub fn tableNextRow(min_height: f32) void {
    c.igTableNextRow(0, min_height);
}

pub fn tableSetupColumn(
    label: [:0]const u8,
    flags: TableColumnFlags,
    init_size: f32,
) void {
    c.igTableSetupColumn(
        label.ptr,
        @bitCast(flags),
        init_size,
        0,
    );
}

pub fn inputTextMultiline(
    label: [:0]const u8,
    buf: []u8,
    size: c.ImVec2,
    flags: InputTextFlags,
) bool {
    return c.igInputTextMultiline(
        label.ptr,
        buf.ptr,
        buf.len,
        size,
        @bitCast(flags),
        null,
        null,
    );
}

pub const WindowFlags = packed struct {
    no_title_bar: bool = false,
    no_resize: bool = false,
    no_move: bool = false,
    no_scrollbar: bool = false,
    no_scrollbar_with_mouse: bool = false,
    no_collapse: bool = false,
    always_auto_resize: bool = false,
    no_background: bool = false,
    no_saved_settings: bool = false,
    no_mouse_inputs: bool = false,
    menu_bar: bool = false,
    horizontal_scroll_bar: bool = false,
    no_focus_on_appearing: bool = false,
    no_bring_to_front_on_focus: bool = false,
    always_vertical_scrollbar: bool = false,
    always_horizontal_scrollbar: bool = false,
    always_use_window_padding: bool = false,
    no_nav_inputs: bool = false,
    no_nav_focus: bool = false,
    unsaved_document: bool = false,
    no_docking: bool = false,
    _unusued_1: u1 = 0,
    nav_flattened: bool = false,
    child_window: bool = false,
    tooltip: bool = false,
    popup: bool = false,
    modal: bool = false,
    child_menu: bool = false,
    dock_node_host: bool = false,
    _padding: u3 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(WindowFlags));
    }
};

pub const TreeNodeFlags = packed struct {
    selected: bool = false,
    framed: bool = false,
    allow_item_overlap: bool = false,
    no_tree_push_on_open: bool = false,
    no_auto_open_on_log: bool = false,
    default_open: bool = false,
    open_on_double_click: bool = false,
    open_on_arrow: bool = false,
    leaf: bool = false,
    bullet: bool = false,
    frame_padding: bool = false,
    span_avail_width: bool = false,
    span_full_width: bool = false,
    nav_left_jumps_back_here: bool = false,
    _padding: u18 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(TreeNodeFlags));
    }
};

pub const TableFlags = packed struct(u32) {
    resizable: bool = false,
    reorderable: bool = false,
    hideable: bool = false,
    sortable: bool = false,
    no_saved_settings: bool = false,
    context_menu_in_body: bool = false,
    row_bg: bool = false,
    borders_inner_h: bool = false,
    borders_outer_h: bool = false,
    borders_inner_v: bool = false,
    borders_outer_v: bool = false,
    no_borders_in_body: bool = false,
    no_borders_in_body_until_resize: bool = false,
    sizing_fixed_fit: bool = false,
    sizing_fixed_same: bool = false,
    sizing_stretch_prop: bool = false,
    sizing_stretch_same: bool = false,
    no_host_extend_x: bool = false,
    no_host_extend_y: bool = false,
    no_keep_columns_visible: bool = false,
    precise_widths: bool = false,
    no_clip: bool = false,
    pad_outer_x: bool = false,
    no_pad_outer_x: bool = false,
    no_pad_inner_x: bool = false,
    scroll_x: bool = false,
    scroll_y: bool = false,
    sort_multi: bool = false,
    sort_tristate: bool = false,
    _padding: u3 = 0,
};

pub const TableColumnFlags = packed struct(u32) {
    disabled: bool = false,
    default_hide: bool = false,
    default_sort: bool = false,
    width_stretch: bool = false,
    width_fixed: bool = false,
    no_resize: bool = false,
    no_reorder: bool = false,
    no_hide: bool = false,
    no_clip: bool = false,
    no_sort: bool = false,
    no_sort_ascending: bool = false,
    no_sort_descending: bool = false,
    no_header_label: bool = false,
    no_header_width: bool = false,
    prefer_sort_ascending: bool = false,
    prefer_sort_descending: bool = false,
    indent_enable: bool = false,
    indent_disable: bool = false,
    is_enabled: bool = false,
    is_visible: bool = false,
    is_sorted: bool = false,
    is_hovered: bool = false,
    _unused: u10 = 0,
};

pub const InputTextFlags = packed struct(c_int) {
    chars_decimal: bool = false,
    chars_hexadecimal: bool = false,
    chars_uppercase: bool = false,
    chars_no_blank: bool = false,
    auto_select_all: bool = false,
    enter_returns_true: bool = false,
    callback_completion: bool = false,
    callback_history: bool = false,
    callback_always: bool = false,
    callback_char_filter: bool = false,
    allow_tab_input: bool = false,
    ctrl_enter_for_newline: bool = false,
    no_horizontal_scroll: bool = false,
    always_overwrite: bool = false,
    read_only: bool = false,
    password: bool = false,
    no_undo_redo: bool = false,
    chars_scientific: bool = false,
    callback_resize: bool = false,
    callback_edit: bool = false,
    _padding: u12 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(InputTextFlags));
    }
};

pub const HoveredFlags = packed struct {
    child_windows: bool = false,
    root_window: bool = false,
    any_window: bool = false,
    no_popup_hierarchy: bool = false,
    dock_hierarchy: bool = false,
    allow_when_blocked_by_popup: bool = false,
    allow_when_blocked_by_active_item: bool = false,
    allow_when_overlapped: bool = false,
    allow_when_disabled: bool = false,
    no_nav_override: bool = false,
    _padding: u22 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(HoveredFlags));
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
