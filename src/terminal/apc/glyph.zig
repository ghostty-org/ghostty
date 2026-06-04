//! # Glyph Protocol
//!
//! The Glyph Protocol lets applications register custom glyphs with the
//! terminal at runtime and query whether a given codepoint is already
//! covered by a system font or a prior registration. It eliminates the
//! requirement for users to install patched fonts (e.g. Nerd Fonts) in
//! order to render icons in TUIs.
//!
//! This file documents the current wire protocol surface parsed and formatted
//! by the glyph APC modules.
//!
//! ## Transport
//!
//! Messages use APC (Application Program Command) framing.
//! Terminals that do not implement the protocol can safely ignore APC
//! sequences. Every message is prefixed with the identifier `25a1`
//! (U+25A1 WHITE SQUARE — the canonical tofu symbol).
//!
//! ## Framing
//!
//! ```
//! ESC _ 25a1 ; <verb> [ ; key=value ]* [ ; <payload> ] ESC \
//! ```
//!
//! Four verbs are defined:
//!
//!   - `s` — support query
//!   - `q` — codepoint query
//!   - `r` — register a glyph
//!   - `c` — clear registrations
//!
//! ## Support (`s`)
//!
//! Detects whether the terminal implements Glyph Protocol and which
//! payload formats it supports.
//!
//! Request:   `ESC _ 25a1 ; s ESC \`
//! Response:  `ESC _ 25a1 ; s ; fmt=<list> ESC \`
//!
//! `fmt` is a comma-separated list of supported payload format names:
//!   - `glyf`   — TrueType simple glyphs (required in v1)
//!   - `colrv0` — COLR v0 layered flat-colour glyphs
//!   - `colrv1` — COLR v1 paint-graph glyphs
//!
//! Order is not significant. An empty `fmt=` means the terminal recognizes
//! Glyph Protocol but currently advertises no payload formats. Clients must
//! ignore unknown format names.
//!
//! Any reply confirms support; no reply within a timeout means the
//! terminal does not implement the protocol.
//!
//! ## Query (`q`)
//!
//! Asks whether a codepoint is renderable and by whom.
//!
//! Request:   `ESC _ 25a1 ; q ; cp=<hex> ESC \`
//! Response:  `ESC _ 25a1 ; q ; cp=<hex> ; status=<list> ESC \`
//!
//! `status` is a comma-separated list of coverage names:
//!   - empty      — nothing renders this codepoint (tofu)
//!   - `system`   — a system font covers it
//!   - `glossary` — a session registration covers it
//!   - `system,glossary` — both; the registration shadows the system font
//!
//! Non-PUA codepoints can only report empty or `system`. Clients must ignore
//! unknown coverage names.
//!
//! ## Register (`r`)
//!
//! Registers a glyph outline at a Private Use Area codepoint.
//!
//! Request:
//!   `ESC _ 25a1 ; r ; cp=<hex> [; fmt=glyf] [; reply=<0|1|2>]
//!         [; upm=<int>] [; aw=<int>] [; lh=<int>] [; width=<1|2>]
//!         [; size=<height|advance|contain|cover|stretch>]
//!         [; align=<start|center|end>,<start|center|end|baseline>]
//!         [; pad=<top>,<right>,<bottom>,<left>] ; <base64-payload> ESC \`
//!
//! Response:
//!   `ESC _ 25a1 ; r ; cp=<hex> ; status=0 ESC \`
//!   On error: `status=<nonzero> ; reason=<code>`
//!
//! Parameters:
//!   - `cp`    — target codepoint (hex). Must be in a PUA range:
//!               U+E000–U+F8FF, U+F0000–U+FFFFD, or U+100000–U+10FFFD.
//!               Non-PUA values are rejected with `reason=out_of_namespace`.
//!   - `fmt`   — payload format. Default `glyf`; `colrv0` and `colrv1`
//!               are optional and advertised via the `s` reply.
//!   - `reply` — response verbosity:
//!               `1` (default) = success + failure replies
//!               `2` = failure replies only (silent success)
//!               `0` = no replies (fire-and-forget)
//!   - `upm`   — units-per-em for the coordinate space. Default 1000.
//!   - `aw`    — authored advance width in upm units. Default `upm`.
//!   - `lh`    — authored line height in upm units. Default `upm`.
//!   - `width` — Unicode/wcwidth cell width. Must be `1` or `2`; default `1`.
//!               This is authoritative for cursor advance, wrapping, and
//!               selection geometry.
//!   - `size`  — scale policy. Default `height`.
//!   - `align` — horizontal and vertical placement within the render span.
//!               Default `center,center`.
//!   - `pad`   — fractional insets from the render span edges. Default
//!               `0,0,0,0`; degenerate padding is treated as no padding.
//!   - payload — base64-encoded payload for the selected `fmt`.
//!
//! The `glyf` subset accepted:
//!   - Simple glyphs only (no composites).
//!   - Standard flag encoding (on-curve, off-curve, x/y-short, repeat).
//!   - No hinting instructions.
//!   - Coordinates are in the `upm` space, Y-up, with `y=0` at the baseline;
//!     the terminal scales and positions at render time using `aw`, `lh`,
//!     `width`, `size`, `align`, and `pad`.
//!
//! `colrv0` and `colrv1` wrap OpenType `COLR`/`CPAL` data together with the
//! simple-glyph outlines they reference. `colrv0` uses layered flat colours;
//! `colrv1` uses the OpenType paint graph and may omit `CPAL` if it does not
//! reference palette indices.
//!
//! A second `r` on the same `cp` overwrites the previous registration.
//! `glyf` outlines render in the current foreground colour.
//!
//! ## Clear (`c`)
//!
//! Removes registrations.
//!
//! Single slot: `ESC _ 25a1 ; c ; cp=<hex> ESC \`
//! All slots:   `ESC _ 25a1 ; c ESC \`
//!
//! The terminal acks with `status=0` even if the slot was already empty.
//! Clear replies do not echo `cp`. `cp` must be in a PUA range; non-PUA values return
//! `reason=out_of_namespace`.
//!
//! ## Glossary Capacity
//!
//! Each session holds at most 1024 registrations keyed by codepoint.
//! Registrations live for the session duration. A 1025th registration
//! evicts the oldest entry (FIFO). Sessions are isolated: two tabs may
//! independently register the same codepoint.
//!
//! ## Security: PUA-Only Restriction
//!
//! Registration is restricted to the three Unicode Private Use Areas to
//! prevent glyph-spoofing attacks. PUA codepoints never appear in normal
//! text (filenames, URLs, commands), so a registered glyph cannot alter
//! how real text is perceived. The cell buffer always stores the original
//! codepoint — copy/paste, search, and hyperlink detection return the
//! codepoint the application emitted, never the rendered glyph.
//!
//! Reference: <https://raw.githubusercontent.com/raphamorim/rio/779dba839dbb76c551f2efa852b82a2ed669101b/specs/glyph-protocol.md>

const std = @import("std");

pub const request = @import("glyph/request.zig");
pub const response = @import("glyph/response.zig");

pub const CommandParser = request.CommandParser;
pub const Request = request.Request;
pub const Response = response.Response;
