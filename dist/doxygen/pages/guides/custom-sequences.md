# Custom Sequences {#guide-custom-sequences}

libghostty-vt gives you two ways to get at escape sequences yourself: a callback
for the sequences we don't implement, and a write function that stops at the
start or end of a control string.

Programs sometimes send sequences we don't implement, such as a newer protocol
or one specific to your application. The terminal discards these by default. And
some applications sit between a shell and a terminal, and need to see exactly
where each string starts and ends in the bytes going past.

Most programs never need this page. If you don't have your own sequences to
handle and you aren't in the middle of someone else's stream, you can skip it.

## Handling sequences we don't implement {#guide-custom-sequences-unknown}

You can ask the terminal to hand these sequences to you, so your application can
implement the protocol itself. Two options work together, and you have to set
both:

- `GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE` installs the callback.
- `GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES` sets how many bytes of each sequence
  to keep. It defaults to zero, which turns the feature off.

The callback receives a GhosttyTerminalUnknownSequence. Its tag says which kind
of sequence arrived. APC and OSC sequences are reported today, and more kinds
may be added later, so ignore any tag you don't handle.

For OSC, the content is everything between `ESC ]` and the terminator, including
the number that identifies the sequence. As an example, suppose your application
invents its own OSC 7400 so that programs can report their status. If a program
writes `ESC ] 7400;status=busy BEL`, the callback receives the content
`7400;status=busy` and the terminator `GHOSTTY_OSC_TERMINATOR_BEL`. Match on the
number followed by `;`, so that `7400;` doesn't also match an unrelated `74000;`
sequence.

We only report numbers we don't recognize. A sequence that uses a number we do
implement, such as OSC 2 for the window title, is never reported, even when its
contents are malformed. We also don't report sequences cut short before their
terminator, or supported protocols that you turned off.

The callback runs while the terminal is processing input, so it can answer a
query by writing straight to the pty. The reply stays in order with the
terminal's own replies. Use the terminator from the request in your reply, since
that's what the program expects. The rules from @ref guide-effects-rules all
apply here.

```c
static void on_unknown_sequence(GhosttyTerminal terminal,
                                void* userdata,
                                const GhosttyTerminalUnknownSequence* seq) {
  (void)terminal;
  if (seq->tag != GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC) return;

  const GhosttyTerminalUnknownOscSequence* osc = &seq->value.osc;

  // This protocol needs the whole sequence, so skip cut-off ones.
  if (osc->truncated) return;

  // Only handle OSC 7400. Everything else is ignored.
  const char prefix[] = "7400;";
  const size_t prefix_len = sizeof(prefix) - 1;
  if (osc->content.len < prefix_len ||
      memcmp(osc->content.ptr, prefix, prefix_len) != 0) return;

  // The content is only valid during this call. Copy it if you need it
  // later. my_app_handle_status is your own function.
  my_app_handle_status(userdata,
                       osc->content.ptr + prefix_len,
                       osc->content.len - prefix_len);
}

// Keep up to 4 KiB of each unknown sequence and report them.
size_t max_bytes = 4096;
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE,
                     (const void*)on_unknown_sequence);
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES,
                     &max_bytes);
```

Pick a limit that fits the largest sequence you expect. A longer sequence is
still reported, with the first bytes up to the limit in its content and
`truncated` set to true. Unknown OSC sequences up to 2048 bytes fit in a buffer
the terminal already owns, so limits up to 2048 add no allocations for OSC.
Larger limits allocate memory for each unknown OSC sequence, and unknown APC
sequences are always kept in allocated memory.

This callback handles both kinds and prints what it gets:

@snippet c-vt-effects/src/main.c effects-unknown-sequence

Full program: @ref c-vt-effects/src/main.c

## Stopping a write at a string boundary {#guide-custom-sequences-write-until}

ghostty_terminal_vt_write_until() works like ghostty_terminal_vt_write(), but it
can pause at points you care about. It tells you exactly where a control string
starts or ends, using the same parse that updates the terminal. A program that
sits between a shell and a terminal can use it to:

- Find the exact bytes of each APC, DCS or OSC string, such as a Kitty graphics
  command, a tmux control mode message or a clipboard write, so it can forward,
  rewrite or drop that string.
- Wait until the stream is at ground before inserting its own sequences, so it
  never splits a sequence from the program.

### Finding string content

After a START stop, the string's content begins at the first byte that wasn't
consumed. For a Kitty graphics command that byte is `G`. For an OSC it's the
first digit of the command number. An END stop consumes the byte that ended the
string, which isn't part of the content. A string can start in one call and end
several calls later.

This loop handles one chunk of output and finds the content of the APC strings
in it. DCS and OSC strings work the same way with their own flags:

```c
uint32_t want = GHOSTTY_TERMINAL_BOUNDARY_APC_START |
                GHOSTTY_TERMINAL_BOUNDARY_APC_END;
size_t off = 0;
while (off < len) {
  GhosttyTerminalWriteStop stop =
      GHOSTTY_INIT_SIZED(GhosttyTerminalWriteStop);
  GhosttyResult r = ghostty_terminal_vt_write_until(
      terminal, data + off, len - off, want, &stop);
  if (r == GHOSTTY_NO_VALUE) {
    // No boundary in the rest of the chunk. Everything was consumed.
    break;
  }

  off += stop.consumed;
  if (stop.reached & GHOSTTY_TERMINAL_BOUNDARY_APC_START) {
    // The content starts at data + off.
  }
  if (stop.reached & GHOSTTY_TERMINAL_BOUNDARY_APC_END) {
    // The ending byte is at data + off - 1. The content stops just
    // before it.
  }
}
```

### Strings that end with ESC

The usual string terminator is the two bytes `ESC \`. The call stops after the
ESC with `GHOSTTY_TERMINAL_STRING_END_ST_ESC` and doesn't consume the `\`. The
loop above needs no special case for this. The `\` is simply the first byte of
the next call, where it completes the terminator and brings the stream back to
ground.

### DCS strings

A DCS_START stop lands on the introducer, before the header. The bytes after it
are the parameters, intermediates and final byte of the header, then the
payload. For `ESC P 1 ; 2 | data ESC \` the stop lands on `P`, and `1;2|` is the
header that follows.

The string can end in its header. CAN, SUB, 0x9C, ESC or another 8-bit control
byte there gives a DCS_END stop for a DCS that never had a payload. Past the
header, only ESC, CAN and SUB end the string, and every other byte is payload,
8-bit bytes included. A 0x90 in the header restarts the header without ending
the string, so it doesn't stop.

### One byte that ends a string and starts another

An 8-bit introducer of a different kind inside an APC, or inside a DCS header,
ends that string and starts the new one on the same byte. The stop has both an
END flag and a START flag in `reached`, `end` is ABORTED and `introducer` is C1.
The content of the new string begins right after the stop.

For example, in `ESC _ a 0x9D 2 ; t BEL` the 0x9D ends the APC and starts an
OSC. Asking for APC_END and OSC_START gives one stop on the 0x9D with both flags
set, `kind` APC and `byte` 0x9D. The OSC content `2;t` begins right after it,
and the BEL then gives an OSC_END stop. GhosttyTerminalWriteStop.reached lists
which bytes do this.

### Waiting for ground

`GHOSTTY_TERMINAL_BOUNDARY_GROUND` is a state, not an event. If the stream is
already at ground, the call returns `GHOSTTY_SUCCESS` right away with `consumed`
set to 0. So if you keep asking for ground with the same input, you never make
progress. After a ground stop, write the next bytes without the GROUND flag, or
with ghostty_terminal_vt_write().
