# Symbols — file icons

Vendored from [miguelsolorio/vscode-symbols](https://github.com/miguelsolorio/vscode-symbols)
by Miguel Solorio, MIT licensed (see `LICENSE`). This is the icon theme
Phantom's file explorer ships with and uses by default.

Only the parts the explorer actually reads were copied:

- `icon-theme.json` — upstream's `src/symbol-icon-theme.json`
- `icons/files/*.svg`, `icons/folders/*.svg` — upstream's `src/icons/`

Upstream's `extension.js` and `lib/` are deliberately **not** vendored.
Phantom reads the theme JSON and the SVGs directly and has no VS Code
extension host, so the JavaScript half has nothing to run against.

## Updating

Copy those same paths from a fresh checkout of upstream. Nothing here is
patched, so an update is a straight overwrite.

## Adding your own

Any SVG-based VS Code icon theme works. Drop the extension's folder — the
one containing its `*icon-theme.json` — into
`~/.config/phantom/icon-themes/` and pick it under the file explorer's
options menu. Font-based themes (VS Code's own Seti, which ships a `.woff`
and keys icons by `fontCharacter`) are listed but disabled: macOS can't
register a WOFF without decompressing it first.
