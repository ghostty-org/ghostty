# Example: `vtStream` API for Parsing Terminal Streams

This example demonstrates how to use the `vtStream` API to parse and process
VT sequences. The `vtStream` API is ideal for read-only terminal applications
that need to parse terminal output without responding to queries, such as:

- Replay tooling
- CI log viewers
- PaaS builder output
- etc.

The stream processes VT escape sequences and updates terminal state, while
ignoring sequences that require responses (like device status queries).

Requires the Zig version stated in the `build.zig.zon` file.

## Usage

Run the program:

```shell-session
zig build run
```

The example will process various VT sequences including:

- Plain text output
- ANSI color codes
- Cursor positioning
- Line clearing
- Multiple line handling

And display the final terminal state after processing all sequences.
