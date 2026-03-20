# Meson Support for libghostty-vt

The top-level `meson.build` wraps the Zig build system so that Meson
projects can consume libghostty-vt without invoking `zig build` manually.
Running `meson compile` triggers `zig build lib-vt` automatically.

This means downstream projects do require a working Zig compiler on
`PATH` to build, but don't need to know any Zig-specific details.

## Using a subproject (recommended)

Create `subprojects/ghostty.wrap`:

```ini
[wrap-git]
url = https://github.com/ghostty-org/ghostty.git
revision = main
depth = 1
```

Then in your project's `meson.build`:

```meson
ghostty_proj = subproject('ghostty')
ghostty_vt_dep = ghostty_proj.get_variable('ghostty_vt_dep')

executable('myapp', 'main.c', dependencies: ghostty_vt_dep)
```

This fetches the Ghostty source, builds libghostty-vt via Zig during your
Meson build, and links it into your target. Headers are added to the
include path automatically.

### Using a local checkout

If you already have the Ghostty source checked out, symlink or copy it
into your `subprojects/` directory:

```shell-session
ln -s /path/to/ghostty subprojects/ghostty
meson setup build
meson compile -C build
```

## Using pkg-config (install-based)

Build and install libghostty-vt first:

```shell-session
cd /path/to/ghostty
meson setup build
meson compile -C build
meson install -C build
```

Then in your project:

```meson
ghostty_vt_dep = dependency('libghostty-vt')

executable('myapp', 'main.c', dependencies: ghostty_vt_dep)
```

## Example

See `example/c-vt-meson/` for a complete working example.
