project('c-vt-meson', 'c',
    version: '0.1.0',
    meson_version: '>= 1.1.0',
)

ghostty_proj = subproject('ghostty')
ghostty_vt_dep = ghostty_proj.get_variable('ghostty_vt_dep')

executable('c_vt_meson', 'src/main.c',
    dependencies: ghostty_vt_dep,
)
