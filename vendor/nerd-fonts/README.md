We have a copy of the `font-patcher` file from `nerd-fonts` here, fetched from
https://github.com/ryanoasis/nerd-fonts/blob/master/font-patcher.

This is MIT licensed, see `LICENSE` in this directory.

We use parse a section of this file to codegen a lookup table of the nerd font
scaling rules. See `src/font/nerd_font_codegen.py` in the main Ghostty source
tree for more info.

Last fetched commit: ebc376cbd43f609d8084f47dd348646595ce066e
