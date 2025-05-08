# GTK UI files

This directory is for storing GTK blueprints. GTK blueprints are compiled into
GTK resource builder `.ui` files by `blueprint-compiler` at build time and then
converted into an embeddable resource by `glib-compile-resources`.

Blueprint files should be stored in directories that represent the minimum
Adwaita version needed to use that resource. Blueprint files should also be
formatted using `blueprint-compiler format` as well to ensure consistency
(formatting will be checked in CI).

`blueprint-compiler` version 0.16.0 or newer is required to compile Blueprint
files. If your system does not have `blueprint-compiler` or does not have a
new enough version you can use the generated source tarballs, which contain
precompiled versions of the blueprints.
