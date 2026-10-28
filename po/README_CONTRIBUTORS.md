# Localizing Ghostty: The Contributors' Guide

Ghostty uses the `gettext` library/framework for localization, which has the
distinct benefit of being able to be consumed directly by our two main
app runtimes: macOS and GTK (Linux). The core would ideally remain agnostic
to localization efforts, as not all consumers of libghostty would be interested
in localization support. Thus, implementors of app runtimes are left responsible
for any localization that they may add.

## GTK

In the GTK app runtime, translatable strings are mainly sourced from Blueprint
files (located under `src/apprt/gtk/ui`). Blueprints have a native syntax for
translatable strings, which look like this:

```zig
// Translators: This is the name of the button that opens the about dialog.
title: _("About Ghostty");
```

The `// Translators:` comment provides additional context to the translator
if the string itself is unclear as to what its purpose is or where it's located.

By default identical strings are collapsed together into one translatable entry.
To avoid this, assign a _context_ to the string:

```zig
label: C_("menu action", "Copy");
```

Translatable strings can also be sourced from Zig source files. This is useful
when the string must be chosen dynamically at runtime, or when it requires
additional formatting. The `i18n.` prefix is necessary as `_` is not allowed
as a bare identifier in Zig.

```zig
const i18n = @import("i18n.zig");

const text = if (awesome)
    i18n._("My awesome label :D")
else
    i18n._("My not-so-awesome label :(");

const label = gtk.Label.new(text);
```

If a string must be stored untranslated and only translated later, use
`i18n.N_` instead. This marks the string for extraction into the translation
template but returns the original msgid unchanged. A common use case is
compile-time or static metadata that is translated only when it is presented
to the user.

```zig
const i18n = @import("i18n.zig");

const Command = struct {
    title: [:0]const u8,
};

const cmd = Command{
    .title = i18n.N_("Reset Terminal"),
};

const label = gtk.Label.new(i18n._(cmd.title));
```

If `i18n._` is called at comptime, it returns the original msgid unchanged
while still marking the string for translation. For strings that are stored
untranslated and translated later, prefer `i18n.N_`.

All translatable strings are extracted into the _translation template file_,
located under `po/com.mitchellh.ghostty.pot`. **This file must stay in sync with
the list of translatable strings present in source code or Blueprints at all times.**
A CI action would be run for every PR, which checks if the translation template
requires any updates. You can update the translation template by running
`zig build update-translations`, which would also synchronize translation files
for other locales (`.po` files) to reflect the state of the template file.

During the build process, each locale in `.po` files is compiled
into binary `.mo` files, stored under `share/locale/<LOCALE>/LC_MESSAGES/com.mitchellh.ghostty.mo`.
This can be directly accessed by `libintl`, which provide the various `gettext`
C functions that can be called either by Zig code directly, or by the GTK builder
(recommended).

> [!NOTE]
> For the vast majority of users, no additional library needs to be installed
> in order to get localizations, since `libintl` is a part of the GNU C standard
> library. For users using alternative C standard libraries like musl, they must
> use a stub implementation such as [`gettext-tiny`](https://github.com/sabotage-linux/gettext-tiny)
> that offer no-op symbols for the translation functions, or by using a build of
> `libintl` that works for them.

## macOS

> [!NOTE]
> The localization system is not yet implemented for macOS.
