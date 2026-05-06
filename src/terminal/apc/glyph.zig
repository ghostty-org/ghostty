//! # Glyph Protocol
//!
//! The Glyph Protocol lets applications register custom glyphs with the
//! terminal at runtime and query whether a given codepoint is already
//! covered by a system font or a prior registration. It eliminates the
//! requirement for users to install patched fonts (e.g. Nerd Fonts) in
//! order to render icons in TUIs.
//!
//! This file documents the wire protocol surface implemented by the parser
//! and response formatter below.
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
//! Response:  `ESC _ 25a1 ; s ; fmt=<bitfield> ESC \`
//!
//! `fmt` bits:
//!   - bit 0 (`1`): `glyf`   — TrueType simple glyphs (required in v1)
//!   - bit 1 (`2`): `colrv0` — COLR v0 layered flat-colour glyphs
//!   - bit 2 (`4`): `colrv1` — COLR v1 paint-graph glyphs
//!
//! Any reply confirms support; no reply within a timeout means the
//! terminal does not implement the protocol.
//!
//! ## Query (`q`)
//!
//! Asks whether a codepoint is renderable and by whom.
//!
//! Request:   `ESC _ 25a1 ; q ; cp=<hex> ESC \`
//! Response:  `ESC _ 25a1 ; q ; cp=<hex> ; status=<u8> ESC \`
//!
//! `status` is a two-bit field:
//!   - `0` (`free`)     — nothing renders this codepoint (tofu)
//!   - `1` (`system`)   — a system font covers it
//!   - `2` (`glossary`) — a session registration covers it
//!   - `3` (`both`)     — both; the registration shadows the system font
//!
//! ## Register (`r`)
//!
//! Registers a glyph outline at a Private Use Area codepoint.
//!
//! Request:
//!   `ESC _ 25a1 ; r ; cp=<hex> [; fmt=glyf] [; upm=<int>]
//!         [; reply=<0|1|2>] ; <base64-payload> ESC \`
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
//!   - `upm`   — units-per-em for the coordinate space. Default 1000.
//!   - `reply` — response verbosity:
//!               `1` (default) = success + failure replies
//!               `2` = failure replies only (silent success)
//!               `0` = no replies (fire-and-forget)
//!   - payload — base64-encoded `glyf` simple-glyph record.
//!
//! The `glyf` subset accepted:
//!   - Simple glyphs only (no composites).
//!   - Standard flag encoding (on-curve, off-curve, x/y-short, repeat).
//!   - No hinting instructions.
//!   - Coordinates are in the `upm` space; the terminal scales to cell size.
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
//! Reference: <https://rapha.land/introducing-glyph-protocol-for-terminals/>

const std = @import("std");

pub const request = @import("glyph/request.zig");
pub const response = @import("glyph/response.zig");

pub const CommandParser = request.CommandParser;
pub const Request = request.Request;
pub const Response = response.Response;
