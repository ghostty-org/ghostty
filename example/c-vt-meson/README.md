# c-vt-meson

Demonstrates consuming libghostty-vt from a Meson project using a
subproject. Creates a terminal, writes VT sequences into it, and
formats the screen contents as plain text.

## Building this example

Since this example lives inside the Ghostty repo, point the subproject
at the local checkout instead of fetching from GitHub:

```shell-session
cd example/c-vt-meson
mkdir -p subprojects
ln -s ../../.. subprojects/ghostty
meson setup build
meson compile -C build
./build/c_vt_meson
```

## Real World Usage

Create a `subprojects/ghostty.wrap` file in your project:

```ini
[wrap-git]
url = https://github.com/ghostty-org/ghostty.git
revision = main
depth = 1
```

Then in your `meson.build`:

```meson
ghostty_proj = subproject('ghostty')
ghostty_vt_dep = ghostty_proj.get_variable('ghostty_vt_dep')

executable('myapp', 'src/main.c', dependencies: ghostty_vt_dep)
```

Meson will clone the repository into `subprojects/ghostty/` on first
build and invoke `zig build lib-vt` automatically.
