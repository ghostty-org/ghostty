meta:
  id: ghostty_snapshot
  title: Ghostty terminal snapshot
  application: Ghostty
  license: MIT
  endian: le
doc: |
  Ghostty terminal snapshot format version 1.

  A complete snapshot contains an envelope, terminal-wide state, one or two
  renderable screen sequences, one raw standard-Stream CONTINUATION, a READY
  marker, matching history sequences, and a FINISH marker. SCREEN pages
  are oldest-to-newest. HISTORY pages are newest-to-oldest. FINISH terminates the
  snapshot; bytes that follow belong to the containing transport and are outside
  this schema. Each SCREEN declares its complete logical history extent before
  READY.

  Record CRC32C values are represented here but cannot be calculated by
  portable Kaitai Struct expressions. The adjacent verify-kaitai.py script
  validates those values after parsing.
seq:
  - id: envelope
    type: envelope
  - id: terminal
    type: terminal_record
  - id: screens
    type: screen_sequence
    repeat: expr
    repeat-expr: terminal.payload.header.screen_count
  - id: continuation
    type: continuation_record
  - id: ready
    type: checkpoint_record(5)
  - id: histories
    type: history_sequence
    repeat: expr
    repeat-expr: terminal.payload.header.screen_count
  - id: finish
    type: checkpoint_record(6)
enums:
  record_tag:
    1: terminal
    2: screen
    3: page
    4: history
    5: ready
    6: finish
    7: continuation
  screen_key:
    0: primary
    1: alternate
  cursor_style:
    0: bar
    1: block
    2: underline
    3: block_hollow
  status_display:
    0: main
    1: status_line
  shell_redraw:
    0: full
    1: none
    2: last
  mouse_event:
    0: none
    1: x10
    2: normal
    3: button
    4: any
  mouse_format:
    0: x10
    1: utf8
    2: sgr
    3: urxvt
    4: sgr_pixels
  mouse_shape:
    0: default
    1: context_menu
    2: help
    3: pointer
    4: progress
    5: wait
    6: cell
    7: crosshair
    8: text
    9: vertical_text
    10: alias
    11: copy
    12: move
    13: no_drop
    14: not_allowed
    15: grab
    16: grabbing
    17: all_scroll
    18: col_resize
    19: row_resize
    20: n_resize
    21: e_resize
    22: s_resize
    23: w_resize
    24: ne_resize
    25: nw_resize
    26: se_resize
    27: sw_resize
    28: ew_resize
    29: ns_resize
    30: nesw_resize
    31: nwse_resize
    32: zoom_in
    33: zoom_out
  protected_mode:
    0: "off"
    1: iso
    2: dec
  semantic_click_kind:
    0: none
    1: click_events
    2: cl
  color_kind:
    0: none
    1: palette
    2: rgb
  hyperlink_kind:
    0: none
    1: implicit
    2: explicit
  cell_content_kind:
    0: codepoint
    1: background_palette
    2: background_rgb
  cell_width:
    0: narrow
    1: wide
    2: spacer_tail
    3: spacer_head
  underline:
    0: none
    1: single
    2: double
    3: curly
    4: dotted
    5: dashed
  semantic_content:
    0: output
    1: input
    2: prompt
  semantic_prompt:
    0: none
    1: prompt
    2: prompt_continuation
types:
  envelope:
    doc: Fixed ten-byte snapshot identification and version header.
    seq:
      - id: magic
        contents: [0x47, 0x48, 0x4f, 0x53, 0x54, 0x53, 0x4e, 0x50]
      - id: version
        type: u2
        valid: 1

  record_header:
    doc: |
      Common record framing. crc32c covers the encoded tag, payload length,
      and payload bytes, excluding the crc32c field itself.
    params:
      - id: expected_tag
        type: u2
    seq:
      - id: tag
        type: u2
        valid: expected_tag
      - id: payload_length
        type: u4
      - id: crc32c
        type: u4

  terminal_record:
    seq:
      - id: header
        type: record_header(1)
      - id: payload
        type: terminal_payload
        size: header.payload_length

  screen_record:
    seq:
      - id: header
        type: record_header(2)
      - id: payload
        type: screen_payload
        size: header.payload_length

  page_record:
    seq:
      - id: header
        type: record_header(3)
      - id: payload
        type: page_payload
        size: header.payload_length

  history_record:
    seq:
      - id: header
        type: record_header(4)
      - id: payload
        type: history_payload
        size: header.payload_length

  continuation_record:
    doc: |
      Raw canonical standard TerminalStream continuation bytes. An empty
      payload explicitly represents ground state.
    seq:
      - id: header
        type: record_header(7)
      - id: payload
        size: header.payload_length

  checkpoint_record:
    doc: READY and FINISH are empty marker records.
    params:
      - id: expected_tag
        type: u2
    seq:
      - id: header
        type: record_header(expected_tag)
      - id: payload
        size: header.payload_length
        valid:
          expr: _.size == 0

  screen_sequence:
    doc: SCREEN followed by its declared PAGE records, oldest-to-newest.
    seq:
      - id: screen
        type: screen_record
      - id: pages
        type: page_record
        repeat: expr
        repeat-expr: screen.payload.header.page_count

  history_sequence:
    doc: HISTORY followed by its declared PAGE records, newest-to-oldest.
    seq:
      - id: history
        type: history_record
      - id: pages
        type: page_record
        repeat: expr
        repeat-expr: history.payload.page_count

  terminal_payload:
    seq:
      - id: header
        type: terminal_header
      - id: tab_stops
        type: tab_stops(header.columns)
      - id: original_palette
        type: rgb
        repeat: expr
        repeat-expr: 256
      - id: palette_override_mask
        size: 32
      - id: palette_overrides
        type: palette_override(palette_override_mask, _index)
        repeat: expr
        repeat-expr: 256
      - id: len_pwd
        type: u4
      - id: pwd
        size: len_pwd
      - id: len_title
        type: u4
      - id: title
        size: len_title
      - id: trailing_data
        size-eos: true
        valid:
          expr: _.size == 0

  terminal_header:
    seq:
      - id: columns
        type: u2
        valid:
          min: 1
      - id: rows
        type: u2
        valid:
          min: 1
      - id: width_px
        type: u4
      - id: height_px
        type: u4
      - id: scrolling_region_top
        type: u2
      - id: scrolling_region_bottom
        type: u2
        valid:
          expr: _ >= scrolling_region_top and _ < rows
      - id: scrolling_region_left
        type: u2
      - id: scrolling_region_right
        type: u2
        valid:
          expr: _ >= scrolling_region_left and _ < columns
      - id: status_display
        type: u1
        enum: status_display
        valid:
          expr: _.to_i <= 1
      - id: active_screen_key
        type: u2
        enum: screen_key
        valid:
          expr: _.to_i <= 1
      - id: screen_count
        type: u2
        valid:
          expr: (_ == 1 or _ == 2) and (active_screen_key.to_i == 0 or _ == 2)
      - id: previous_codepoint
        type: u4
        valid:
          expr: _ == 0xffffffff or (_ <= 0x10ffff and not (_ >= 0xd800 and _ <= 0xdfff))
      - id: cursor_is_default
        type: u1
        valid:
          max: 1
      - id: cursor_default_style
        type: u1
        enum: cursor_style
        valid:
          expr: _.to_i <= 3
      - id: cursor_default_blink
        type: u1
        valid:
          max: 2
      - id: shell_redraw
        type: u1
        enum: shell_redraw
        valid:
          expr: _.to_i <= 2
      - id: modify_other_keys_2
        type: u1
        valid:
          max: 1
      - id: mouse_event
        type: u1
        enum: mouse_event
        valid:
          expr: _.to_i <= 4
      - id: mouse_format
        type: u1
        enum: mouse_format
        valid:
          expr: _.to_i <= 4
      - id: mouse_shift_capture
        type: u1
        valid:
          max: 2
      - id: mouse_shape
        type: u1
        enum: mouse_shape
        valid:
          expr: _.to_i <= 33
      - id: password_input
        type: u1
        valid:
          max: 1
      - id: current_modes
        type: mode_set
      - id: saved_modes
        type: mode_set
      - id: default_modes
        type: mode_set
      - id: background
        type: dynamic_rgb
      - id: foreground
        type: dynamic_rgb
      - id: cursor_color
        type: dynamic_rgb
      - id: max_scrollback_bytes
        type: u8
      - id: max_scrollback_rows
        type: u8

  mode_set:
    doc: |
      The stable packed registry shared by current, saved, and default modes.
      Each named instance exposes one bit from the little-endian integer.
      Arithmetic division is used instead of bitwise operations because the
      JavaScript target implements those operations with signed 32-bit values.
      All values remain exact because the registry occupies only 43 bits,
      within JavaScript's 53-bit safe integer range.
    seq:
      - id: raw
        type: u8
        valid:
          max: 8796093022207
    instances:
      disable_keyboard:
        value: (raw / 1) % 2 != 0
      insert:
        value: (raw / 2) % 2 != 0
      send_receive_mode:
        value: (raw / 4) % 2 != 0
      linefeed:
        value: (raw / 8) % 2 != 0
      cursor_keys:
        value: (raw / 16) % 2 != 0
      column_132:
        value: (raw / 32) % 2 != 0
      slow_scroll:
        value: (raw / 64) % 2 != 0
      reverse_colors:
        value: (raw / 128) % 2 != 0
      origin:
        value: (raw / 256) % 2 != 0
      wraparound:
        value: (raw / 512) % 2 != 0
      autorepeat:
        value: (raw / 1024) % 2 != 0
      mouse_event_x10:
        value: (raw / 2048) % 2 != 0
      cursor_blinking:
        value: (raw / 4096) % 2 != 0
      cursor_visible:
        value: (raw / 8192) % 2 != 0
      enable_mode_3:
        value: (raw / 16384) % 2 != 0
      reverse_wrap:
        value: (raw / 32768) % 2 != 0
      alt_screen_legacy:
        value: (raw / 65536) % 2 != 0
      keypad_keys:
        value: (raw / 131072) % 2 != 0
      backarrow_key_mode:
        value: (raw / 262144) % 2 != 0
      enable_left_and_right_margin:
        value: (raw / 524288) % 2 != 0
      mouse_event_normal:
        value: (raw / 1048576) % 2 != 0
      mouse_event_button:
        value: (raw / 2097152) % 2 != 0
      mouse_event_any:
        value: (raw / 4194304) % 2 != 0
      focus_event:
        value: (raw / 8388608) % 2 != 0
      mouse_format_utf8:
        value: (raw / 16777216) % 2 != 0
      mouse_format_sgr:
        value: (raw / 33554432) % 2 != 0
      mouse_alternate_scroll:
        value: (raw / 67108864) % 2 != 0
      mouse_format_urxvt:
        value: (raw / 134217728) % 2 != 0
      mouse_format_sgr_pixels:
        value: (raw / 268435456) % 2 != 0
      ignore_keypad_with_numlock:
        value: (raw / 536870912) % 2 != 0
      alt_esc_prefix:
        value: (raw / 1073741824) % 2 != 0
      alt_sends_escape:
        value: (raw / 2147483648) % 2 != 0
      reverse_wrap_extended:
        value: (raw / 4294967296) % 2 != 0
      alt_screen:
        value: (raw / 8589934592) % 2 != 0
      save_cursor:
        value: (raw / 17179869184) % 2 != 0
      alt_screen_save_cursor_clear_enter:
        value: (raw / 34359738368) % 2 != 0
      bracketed_paste:
        value: (raw / 68719476736) % 2 != 0
      synchronized_output:
        value: (raw / 137438953472) % 2 != 0
      grapheme_cluster:
        value: (raw / 274877906944) % 2 != 0
      report_color_scheme:
        value: (raw / 549755813888) % 2 != 0
      report_visibility:
        value: (raw / 1099511627776) % 2 != 0
      in_band_size_reports:
        value: (raw / 2199023255552) % 2 != 0
      kitty_paste_events:
        value: (raw / 4398046511104) % 2 != 0

  tab_stops:
    params:
      - id: columns
        type: u2
    seq:
      - id: complete_bytes
        size: columns / 8
      - id: partial_byte
        type: u1
        if: columns % 8 != 0
        valid:
          expr: _ < (1 << (columns % 8))

  rgb:
    seq:
      - id: red
        type: u1
      - id: green
        type: u1
      - id: blue
        type: u1

  dynamic_rgb:
    seq:
      - id: default_present
        type: u1
        valid:
          max: 1
      - id: default_red
        type: u1
        valid:
          expr: default_present == 1 or _ == 0
      - id: default_green
        type: u1
        valid:
          expr: default_present == 1 or _ == 0
      - id: default_blue
        type: u1
        valid:
          expr: default_present == 1 or _ == 0
      - id: override_present
        type: u1
        valid:
          max: 1
      - id: override_red
        type: u1
        valid:
          expr: override_present == 1 or _ == 0
      - id: override_green
        type: u1
        valid:
          expr: override_present == 1 or _ == 0
      - id: override_blue
        type: u1
        valid:
          expr: override_present == 1 or _ == 0

  palette_override:
    params:
      - id: mask
        type: bytes
      - id: index
        type: u2
    seq:
      - id: color
        type: rgb
        if: (mask[index / 8] & (1 << (index % 8))) != 0

  screen_payload:
    seq:
      - id: header
        type: screen_header
      - id: saved_cursor
        type: saved_cursor
        if: header.saved_cursor_present == 1
      - id: cursor_hyperlink
        type: hyperlink(true, false)
      - id: trailing_data
        size-eos: true
        valid:
          expr: _.size == 0

  screen_header:
    seq:
      - id: key
        type: u2
        enum: screen_key
        valid:
          expr: _.to_i <= 1
      - id: page_count
        type: u2
        valid:
          min: 1
      - id: history_rows
        type: u8
      - id: cursor_x
        type: u2
      - id: cursor_y
        type: u2
      - id: cursor_style
        type: u1
        enum: cursor_style
        valid:
          expr: _.to_i <= 3
      - id: cursor_flags
        type: cursor_flags
      - id: cursor_pen
        type: style
      - id: hyperlink_implicit_id
        type: u4
      - id: charset
        type: charset_state
      - id: protected_mode
        type: u1
        enum: protected_mode
        valid:
          expr: _.to_i <= 2
      - id: kitty_keyboard_index
        type: u1
        valid:
          max: 7
      - id: kitty_keyboard_flags
        type: kitty_keyboard_flags
        repeat: expr
        repeat-expr: 8
      - id: semantic_click_kind
        type: u1
        enum: semantic_click_kind
        valid:
          expr: _.to_i <= 2
      - id: semantic_click_value
        type: u1
        valid:
          expr: |
            semantic_click_kind.to_i == 0 ? _ == 0 :
            semantic_click_kind.to_i == 1 ? _ <= 1 :
            _ <= 3
      - id: saved_cursor_present
        type: u1
        valid:
          max: 1

  cursor_flags:
    seq:
      - id: raw
        type: u1
        valid:
          expr: (_ & 0xe0) == 0 and ((_ >> 2) & 0x3) <= 2
    instances:
      pending_wrap:
        value: (raw & (1 << 0)) != 0
      protected:
        value: (raw & (1 << 1)) != 0
      semantic_content:
        value: (raw >> 2) & 0x3
      semantic_content_clear_eol:
        value: (raw & (1 << 4)) != 0

  charset_state:
    doc: |
      Four selected character sets, the GL and GR slots, and an optional
      single-shift slot. single_shift is zero for none or one plus a slot.
    seq:
      - id: raw
        type: u2
        valid:
          expr: (_ & 0x8000) == 0 and ((_ >> 12) & 0x7) <= 4
    instances:
      g0:
        value: (raw >> 0) & 0x3
      g1:
        value: (raw >> 2) & 0x3
      g2:
        value: (raw >> 4) & 0x3
      g3:
        value: (raw >> 6) & 0x3
      gl:
        value: (raw >> 8) & 0x3
      gr:
        value: (raw >> 10) & 0x3
      single_shift:
        value: (raw >> 12) & 0x7

  kitty_keyboard_flags:
    seq:
      - id: raw
        type: u1
        valid:
          expr: (_ & 0xe0) == 0
    instances:
      disambiguate:
        value: (raw & (1 << 0)) != 0
      report_events:
        value: (raw & (1 << 1)) != 0
      report_alternates:
        value: (raw & (1 << 2)) != 0
      report_all:
        value: (raw & (1 << 3)) != 0
      report_associated:
        value: (raw & (1 << 4)) != 0

  saved_cursor:
    seq:
      - id: x
        type: u2
      - id: y
        type: u2
      - id: pen
        type: style
      - id: flags
        type: saved_cursor_flags
      - id: charset
        type: charset_state

  saved_cursor_flags:
    seq:
      - id: raw
        type: u1
        valid:
          expr: (_ & 0xf8) == 0
    instances:
      protected:
        value: (raw & (1 << 0)) != 0
      pending_wrap:
        value: (raw & (1 << 1)) != 0
      origin:
        value: (raw & (1 << 2)) != 0

  history_payload:
    seq:
      - id: key
        type: u2
        enum: screen_key
        valid:
          expr: _.to_i <= 1
      - id: page_count
        type: u4
      - id: trailing_data
        size-eos: true
        valid:
          expr: _.size == 0

  page_payload:
    seq:
      - id: header
        type: page_header
      - id: styles
        type: style_table_entry
        repeat: expr
        repeat-expr: header.style_count
      - id: hyperlinks
        type: hyperlink_table_entry
        repeat: expr
        repeat-expr: header.hyperlink_count
      - id: grid
        type: grid(header.rows, header.columns)
      - id: trailing_data
        size-eos: true
        valid:
          expr: _.size == 0

  page_header:
    seq:
      - id: columns
        type: u2
        valid:
          min: 1
      - id: rows
        type: u2
        valid:
          min: 1
      - id: style_count
        type: u2
      - id: hyperlink_count
        type: u2
      - id: style_capacity
        type: u2
      - id: hyperlink_capacity_bytes
        type: u2
      - id: grapheme_capacity_bytes
        type: u4
      - id: string_capacity_bytes
        type: u4

  style_table_entry:
    seq:
      - id: encoded_id
        type: u2
        valid:
          min: 1
      - id: value
        type: style

  hyperlink_table_entry:
    seq:
      - id: encoded_id
        type: u2
        valid:
          min: 1
      - id: value
        type: hyperlink(false, true)

  style:
    seq:
      - id: foreground
        type: style_color
      - id: background
        type: style_color
      - id: underline_color
        type: style_color
      - id: flags
        type: style_flags
      - id: reserved
        type: u2
        valid: 0

  style_flags:
    seq:
      - id: raw
        type: u2
        valid:
          expr: (_ & 0xf800) == 0 and ((_ >> 8) & 0x7) <= 5
    instances:
      bold:
        value: (raw & (1 << 0)) != 0
      italic:
        value: (raw & (1 << 1)) != 0
      faint:
        value: (raw & (1 << 2)) != 0
      blink:
        value: (raw & (1 << 3)) != 0
      inverse:
        value: (raw & (1 << 4)) != 0
      invisible:
        value: (raw & (1 << 5)) != 0
      strikethrough:
        value: (raw & (1 << 6)) != 0
      overline:
        value: (raw & (1 << 7)) != 0
      underline:
        value: (raw >> 8) & 0x7

  style_color:
    seq:
      - id: kind
        type: u1
        enum: color_kind
        valid:
          expr: _.to_i <= 2
      - id: first
        type: u1
        valid:
          expr: kind.to_i != 0 or _ == 0
      - id: second
        type: u1
        valid:
          expr: kind.to_i == 2 or _ == 0
      - id: third
        type: u1
        valid:
          expr: kind.to_i == 2 or _ == 0

  hyperlink:
    params:
      - id: allow_none
        type: bool
      - id: allow_empty
        type: bool
    seq:
      - id: kind
        type: u1
        enum: hyperlink_kind
        valid:
          expr: _.to_i <= 2 and (allow_none or _.to_i != 0)
      - id: implicit
        type: implicit_hyperlink(allow_empty)
        if: kind.to_i == 1
      - id: explicit
        type: explicit_hyperlink(allow_empty)
        if: kind.to_i == 2

  implicit_hyperlink:
    params:
      - id: allow_empty
        type: bool
    seq:
      - id: id
        type: u4
      - id: len_uri
        type: u4
        valid:
          expr: allow_empty or _ >= 1
      - id: uri
        size: len_uri

  explicit_hyperlink:
    params:
      - id: allow_empty
        type: bool
    seq:
      - id: len_id
        type: u4
        valid:
          expr: allow_empty or _ >= 1
      - id: id
        size: len_id
      - id: len_uri
        type: u4
        valid:
          expr: allow_empty or _ >= 1
      - id: uri
        size: len_uri

  grid:
    params:
      - id: num_rows
        type: u2
      - id: columns
        type: u2
    seq:
      - id: rows
        type: grid_row(columns)
        repeat: expr
        repeat-expr: num_rows
      - id: num_grapheme_entries
        type: u4
      - id: grapheme_entries
        type: grapheme_entry(num_rows, columns)
        repeat: expr
        repeat-expr: num_grapheme_entries

  grid_row:
    params:
      - id: columns
        type: u2
    seq:
      - id: flags
        type: grid_row_flags
      - id: cell_count
        type: u2
        valid:
          expr: _ <= columns
      - id: cells
        type:
          switch-on: flags.width_log2
          cases:
            0: grid_cell_1
            1: grid_cell_2
            2: grid_cell_4
            3: grid_cell(_index, columns, flags.wrap)
        repeat: expr
        repeat-expr: cell_count

  grid_row_flags:
    seq:
      - id: raw
        type: u1
        valid:
          expr: (_ & 0xc0) == 0 and ((_ >> 2) & 0x3) <= 2
    instances:
      wrap:
        value: (raw & 1) != 0
      wrap_continuation:
        value: (raw & 2) != 0
      semantic_prompt:
        value: (raw >> 2) & 0x3
      width_log2:
        value: (raw >> 4) & 0x3

  grid_cell_1:
    doc: One-byte encoded cell; the value is a codepoint at or below U+00FF.
    seq:
      - id: codepoint
        type: u1

  grid_cell_2:
    doc: |
      Two-byte encoded cell; the value is a codepoint at or below U+FFFF.
      Canonical encoders never emit surrogates.
    seq:
      - id: codepoint
        type: u2
        valid:
          expr: not (_ >= 0xd800 and _ <= 0xdfff)

  grid_cell_4:
    doc: |
      Four-byte encoded cell holding the low half of the cell word: any
      content kind and codepoint, style IDs one through sixty-three, and no
      width, flag, or hyperlink bits.
    seq:
      - id: raw
        type: u4
        valid:
          expr: |
            (content_kind >= 2 or
              (content <= 0x10ffff and
                not (content >= 0xd800 and content <= 0xdfff))) and
            (content_kind != 2 or content <= 0xff)
    instances:
      content_kind:
        value: raw % 4
      content:
        value: (raw / 4) % 16777216
      style_id:
        value: raw / 67108864

  grid_cell:
    doc: |
      One 64-bit little-endian cell word. The word is parsed as two 32-bit
      halves so every derived field stays within JavaScript's safe integer
      range, following the same approach as mode_set.

      Canonical rules validated here: reserved semantic content is not
      emitted, the hyperlink flag matches a nonzero hyperlink ID, codepoint
      content is a Unicode scalar value, palette content uses only its low
      eight bits, and spacer relationships match the preceding cell. Wide
      markers cannot be validated forward because their spacer tail may be
      the next cell or the implicit narrow cell after a short row.
    params:
      - id: index
        type: u2
      - id: columns
        type: u2
      - id: row_wrap
        type: bool
    seq:
      - id: lo
        type: u4
      - id: hi
        type: u4
        valid:
          expr: |
            semantic_content <= 2 and
            hyperlink == (hyperlink_id != 0) and
            (content_kind >= 2 or
              (content <= 0x10ffff and
                not (content >= 0xd800 and content <= 0xdfff))) and
            (content_kind != 2 or content <= 0xff) and
            (width != 2 or
              (index > 0 and
                _parent.cells[index - 1].as<grid_cell>.width == 1)) and
            (width != 3 or (index + 1 == columns and row_wrap))
    instances:
      content_kind:
        value: lo % 4
      content:
        value: (lo / 4) % 16777216
      style_id:
        value: (lo / 67108864) + (hi % 1024) * 64
      width:
        value: (hi / 1024) % 4
      protected:
        value: (hi / 4096) % 2 != 0
      hyperlink:
        value: (hi / 8192) % 2 != 0
      semantic_content:
        value: (hi / 16384) % 4
      hyperlink_id:
        value: hi / 65536

  grapheme_entry:
    seq:
      - id: row
        type: u2
        valid:
          expr: _ < num_rows
      - id: col
        type: u2
        valid:
          expr: _ < columns
      - id: num_codepoints
        type: u2
        valid:
          min: 1
      - id: codepoints
        type: u4
        repeat: expr
        repeat-expr: num_codepoints
        valid:
          expr: _ <= 0x10ffff and not (_ >= 0xd800 and _ <= 0xdfff)
    params:
      - id: num_rows
        type: u2
      - id: columns
        type: u2
