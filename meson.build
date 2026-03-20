# Meson wrapper for libghostty-vt
#
# This file delegates to `zig build lib-vt` to produce the shared library,
# headers, and pkg-config file. It exists so that Meson-based projects can
# consume libghostty-vt without interacting with the Zig build system
# directly. However, downstream users do still require `zig` on the PATH.
# Please consult the Ghostty docs for the required Zig version:
#
# https://ghostty.org/docs/install/build
#
# Building within the Ghostty repo
# ---------------------------------
#
#   meson setup build
#   meson compile -C build
#   meson install -C build
#
# Pass extra flags to the Zig build with -Dzig-build-flags:
#
#   meson setup build -Dzig-build-flags='-Demit-macos-app=false'
#
# Integrating into a downstream Meson project
# ---------------------------------------------
#
# Option 1 — Meson subproject with a .wrap file (recommended):
#
#   Create subprojects/ghostty.wrap:
#
#     [wrap-git]
#     url = https://github.com/ghostty-org/ghostty.git
#     revision = main
#     depth = 1
#
#   Then in your meson.build:
#
#     ghostty_proj = subproject('ghostty')
#     ghostty_vt_dep = ghostty_proj.get_variable('ghostty_vt_dep')
#     executable('myapp', 'main.c', dependencies: ghostty_vt_dep)
#
# Option 2 — pkg-config (after installing to a prefix):
#
#     ghostty_vt_dep = dependency('libghostty-vt')
#     executable('myapp', 'main.c', dependencies: ghostty_vt_dep)
#
# See dist/meson/README.md for more details and example/c-vt-meson/ for a
# complete working example.

project('ghostty-vt', 'c',
    version: '0.1.0',
    meson_version: '>= 1.1.0',
)

# --- Options ----------------------------------------------------------------

zig_build_flags = get_option('zig-build-flags')

# --- Find Zig ----------------------------------------------------------------

zig = find_program('zig', required: true)
message('Found zig: ' + zig.full_path())

# --- Build via zig build -----------------------------------------------------

# Use --prefix to direct zig build output into the Meson build directory
# so the library is a proper declared output of the custom target.
zig_out_dir = meson.current_build_dir() / 'zig-out'

# Determine library filenames per platform.
if host_machine.system() == 'darwin'
    ghostty_vt_libname = 'libghostty-vt.dylib'
    ghostty_vt_soname = 'libghostty-vt.0.dylib'
    ghostty_vt_realname = 'libghostty-vt.0.1.0.dylib'
elif host_machine.system() == 'windows'
    ghostty_vt_libname = 'ghostty-vt.dll'
    ghostty_vt_realname = 'ghostty-vt.dll'
    ghostty_vt_soname = ''
else
    ghostty_vt_libname = 'libghostty-vt.so'
    ghostty_vt_soname = 'libghostty-vt.so.0'
    ghostty_vt_realname = 'libghostty-vt.so.0.1.0'
endif

# Custom target: run zig build lib-vt with --prefix pointing into the build dir.
# Use --prefix-lib-dir to place the library directly in the custom_target
# output directory, and --prefix-include-dir for the headers.
#
# We declare a sentinel .h file as a second output so that Meson creates a
# compile-time ordering dependency (Meson only orders compiles before
# custom_target outputs that look like headers).
zig_build_cmd = [zig, 'build', 'lib-vt',
    '--prefix-lib-dir', meson.current_build_dir(),
    '--prefix-include-dir', zig_out_dir / 'include',
]
if zig_build_flags != ''
    zig_build_cmd += zig_build_flags.split()
endif

zig_build_lib_vt = custom_target('zig_build_lib_vt',
    output: [ghostty_vt_realname, 'ghostty-vt-sentinel.h'],
    command: [
        'sh', '-c', '"$@" && touch @OUTPUT1@', 'sh',
        zig_build_cmd,
    ],
    console: true,
    install: true,
    install_dir: [get_option('libdir'), false],
)

# --- Declare dependency for subproject consumers ------------------------------

ghostty_vt_lib = declare_dependency(
    compile_args: ['-I' + zig_out_dir / 'include'],
    sources: zig_build_lib_vt,
    link_args: [
        '-L' + meson.current_build_dir(),
        '-lghostty-vt',
        '-Wl,-rpath,' + meson.current_build_dir(),
    ],
)

# Expose for subproject() consumers via get_variable('ghostty_vt_dep')
ghostty_vt_dep = ghostty_vt_lib

# --- Install ------------------------------------------------------------------

if host_machine.system() != 'windows'
    # Install symlinks
    meson.add_install_script('sh', '-c',
        'ln -sf "@0@" "$DESTDIR@1@/@2@"'.format(
            ghostty_vt_realname,
            get_option('prefix') / get_option('libdir'),
            ghostty_vt_soname,
        ),
    )
    meson.add_install_script('sh', '-c',
        'ln -sf "@0@" "$DESTDIR@1@/@2@"'.format(
            ghostty_vt_soname,
            get_option('prefix') / get_option('libdir'),
            ghostty_vt_libname,
        ),
    )
endif

# Install headers
meson.add_install_script('sh', '-c',
    'cp -r "@0@/include/ghostty" "$DESTDIR@1@/"'.format(
        zig_out_dir,
        get_option('prefix') / get_option('includedir'),
    ),
)
