# Example: stdin to HTML using `vtStream` and `TerminalFormatter`

This example demonstrates how to read VT sequences from stdin, parse them
using `vtStream`, and output styled HTML using `TerminalFormatter`. The
purpose of this example is primarily to show how to use formatters with
terminals.

Requires the Zig version stated in the `build.zig.zon` file.

## Usage

Basic usage:

```shell-session
echo -e "Hello \033[1;32mGreen\033[0m World" | zig build run
```

This will output HTML with inline styles and CSS palette variables.

You can also pipe complex terminal output:

```shell-session
ls --color=always | zig build run > output.html
```
