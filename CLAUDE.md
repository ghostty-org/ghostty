# term244 作業メモ

term244 は Ghostty(ターミナルエミュレータ)のフォーク。アプリ名を term244 にリブランドし、
HTML/Markdown レンダリングタブの追加や WSL/Windows 対応を進めている。

## 知見ログ

### 2026-05-22: macOS ビルドで Metal Toolchain 不足

- **何が起きたか**: `zig build` の `metal Ghostty (Ghostty.ir)` ステップで
  `error: cannot execute tool 'metal' due to missing Metal Toolchain` が発生。
- **なぜ起きたか**: Xcode 26 では Metal Toolchain が標準同梱されず、別ダウンロード
  コンポーネントになった。Xcode 本体だけでは `metal` コンパイラが無い。
- **どう直したか**: `xcodebuild -downloadComponent MetalToolchain` で導入。
  ビルドスクリプト(`/tmp/term244-build.sh`)に「`xcrun -sdk macosx metal --version`
  で有無を確認し、無ければ自動 DL」する処理を組み込んだ。

### 2026-05-22: リブランドの方針(軽いリブランド)

- `ghostty` 文字列は terminfo(`xterm-ghostty`)・C API シンボル(`ghostty_*`)・
  設定ディレクトリ(`~/.config/ghostty`)・GTK app id にも広く存在し、変えると
  互換性が壊れる。そのため**ユーザーから見える名前だけ**を term244 に変更する。
- 変更済み: `macos/Ghostty.xcodeproj/project.pbxproj`(PRODUCT_NAME / EXECUTABLE_NAME /
  CFBundleDisplayName / PRODUCT_BUNDLE_IDENTIFIER = `com.term244.term244`)、
  `Ghostty.xcscheme` の BuildableName、`src/build/GhosttyXcodebuild.zig` の
  旧名ハードコード(`Ghostty.app` / `ghostty`)。
- 据え置き: terminfo、C API、設定ディレクトリ、Xcode プロジェクト/スキームのファイル名・
  ターゲット名(内部名のため)。
