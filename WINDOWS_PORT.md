# term244 — ネイティブ Windows 移植ロードマップ

term244(Ghostty フォーク)をネイティブ Windows で動かすための実装計画。
macOS 版(リブランド + HTML/Markdown ビューアタブ/ペイン)は完成済み。
Windows 版はここから着手する。

> このドキュメントは Windows マシン側で作業を再開するための土台。
> macOS のチャットセッションでは Windows のビルド・検証ができないため、
> 実装そのものは Windows 環境で進めること。

## 現状サマリ

- **コア(プラットフォーム非依存)**: `src/terminal/`(VT パース・画面バッファ)、
  `src/Surface.zig`、`src/App.zig`。Windows でもそのまま動く。
- **apprt(アプリ層)**: `src/apprt/` に `gtk`(Linux)・`embedded`(macOS の
  Swift アプリが利用)・`none` のみ。**Windows 用 apprt は存在しない** ← 最大の不足。
- **レンダラ**: `src/renderer/` に Metal(macOS)と OpenGL(Linux/GTK)。

## 既に Windows で動く / 再利用できるもの

下回りはかなり揃っている。足りないのは「ガワ(GUI)」だけ。

| 要素 | 状態 | 場所 |
|---|---|---|
| PTY (ConPTY) | ✅ 実装済み | `src/pty.zig` の `WindowsPty`(`CreatePseudoConsole` 等) |
| プロセス起動 | ✅ 実装済み | `src/Command.zig` の `startWindows()`(`CreateProcessW` + ConPTY） |
| Win32 API シム | ✅ あり | `src/os/windows.zig` |
| MSVC ABI | ✅ ビルド設定済み | `src/build/Config.zig`(Windows で `abi = .msvc` 強制) |
| ターミナルコア | ✅ 非依存 | `src/terminal/`、`src/Surface.zig`、`src/App.zig` |
| Windows リソース雛形 | ✅ あり | `dist/windows/ghostty.rc` |

## 不足しているもの(新規実装)

1. **Windows apprt** — ウィンドウ生成・メッセージループ・入力・DPI・
   クリップボード・IPC。`src/apprt/gtk/` が参照実装(Surface だけで ~1500 行）。
2. **OpenGL の WGL コンテキスト経路** — `src/renderer/OpenGL.zig` の
   `surfaceInit`/`threadEnter`/`threadExit`/`displayRealized` が現状
   GTK/embedded 専用 switch。Windows(WGL)ケースを追加。
3. **apprt 選択の配線** — `src/apprt.zig` / `src/apprt/runtime.zig` /
   `build.zig` に `.windows` を追加。
4. **フォント探索** — fontconfig は Linux 専用。Windows は DirectWrite で
   フォント列挙(`src/font/`)。ラスタライズは FreeType を流用可。
5. **単一インスタンス IPC** — D-Bus の代わりに名前付きパイプ or Mutex。

## 実装計画(フェーズ順)

### W1. apprt 選択の配線(小)
- `src/apprt.zig` の runtime 選択 switch に `.windows => windows` を追加。
- `src/apprt/runtime.zig` の `Runtime.default()` で Windows を `.windows` に。
- `build.zig`: Windows ターゲットで `exe` アーティファクトを許可。
- まず空の `src/apprt/windows.zig` を作り、コンパイルが通る骨格にする。

### W2. Windows apprt の骨格(大 — 本丸)
- 新規: `src/apprt/windows.zig`、`src/apprt/windows/App.zig`、
  `src/apprt/windows/Surface.zig`。
- `App`: Win32 メッセージループ(`GetMessage`/`DispatchMessage`)、
  ウィンドウクラス登録。
- `Surface`: `CreateWindowExW` でウィンドウ生成、`WndProc` で入力
  (`WM_KEYDOWN`/`WM_CHAR`/`WM_MOUSE*`)・リサイズ(`WM_SIZE`)・
  描画(`WM_PAINT`)・DPI(`WM_DPICHANGED`)を処理しコアへ転送。
- 参照: `src/apprt/gtk/App.zig` / `src/apprt/gtk/Surface.zig` と
  `src/apprt/embedded.zig`(コアが apprt に求めるメソッド一覧の把握に最適）。
- apprt が実装すべき最小メソッド: `deinit`、`core()`、`getTitle()`、
  `getContentScale()`、`getSize()`、`getCursorPos()`、`supportsClipboard()`、
  `clipboardRequest()`、`setClipboard()`、`defaultTermioEnv()` ほかコールバック群。

### W3. レンダラ(OpenGL + WGL)
- `src/renderer/OpenGL.zig` の apprt 別 switch に `.windows` ケースを追加。
- Surface の `HWND` → `HDC` 取得 → `wglCreateContext`(または
  `WGL_ARB_create_context` で 3.3+ コア)→ レンダラスレッドで `wglMakeCurrent`。
- `displayRealized` 相当を Windows apprt 側から呼んで GL ロード
  (`gl.glad.load`、proc は `wglGetProcAddress`)。
- D3D 新規バックエンドは不要。OpenGL で足りる。

### W4. フォント(DirectWrite)
- `src/font/backend.zig` に Windows 用ディスカバリを追加。`IDWriteFactory`
  でシステムフォント列挙。ラスタライズは既存 FreeType を流用可。

### W5. クリップボード / IPC / 仕上げ
- クリップボード: `OpenClipboard`/`GetClipboardData`/`SetClipboardData`
  (`CF_UNICODETEXT`)。
- 単一インスタンス: 名前付き Mutex + 名前付きパイプで2個目の起動を転送。
- `dist/windows/ghostty.rc` を term244 用に調整。アイコン。パッケージング。

## 推奨着手順とマイルストーン

W1(配線・骨格)→ W2(空ウィンドウが出る所まで)→ W3(GL でターミナル描画)
→ **ここで「文字が出るターミナル」= 最初のマイルストーン** → W4/W5 で実用度向上。

## ビルド & 実行(Windows)

- Zig 0.15.2(`build.zig.zon` の `minimum_zig_version`)。
- W1 で `windows` apprt を追加後:
  `zig build -Dtarget=x86_64-windows-msvc -Dapp-runtime=windows`
- 当面は `zig build` で `.exe` を生成 → 直接実行。

## WSL で開発する場合

WSL(WSL2)を母艦に Windows 移植を開発することも可能。native Windows との
差は実質「`xwin` セットアップ1回」だけ。

- **Claude Code**: WSL2 で完全サポート(full Bash + サンドボックス)。
- **編集**: 問題なし。
- **ビルド(クロスコンパイル)**: WSL(Linux)から
  `zig build -Dtarget=x86_64-windows-msvc` で Windows 向け `.exe` を生成できる。
  MSVC ABI は Windows SDK / MSVC ライブラリを要するため、`xwin`
  (github.com/Jake-Shadle/xwin)で一度だけ取得して Zig に渡す。
  - 代替: `src/build/Config.zig` の MSVC ABI 強制を exe ビルドでは
    `windows-gnu` に緩めれば、Zig が完全自己完結なので `xwin` 不要。
    libghostty-vt を MSVC リンカで使う用途が無いならこちらが楽。
- **実行・テスト**: WSL2 の interop で、生成した `term244.exe` を WSL シェルから
  そのまま起動できる(Windows 側で実行され、ウィンドウは Windows デスクトップに
  出る)。ビルド→実行ループはこれで回せる。
- **デバッグ**: 深い Win32 のデバッグはネイティブ Windows のツール
  (Visual Studio デバッガ等)の方が楽。要所だけ native 側で確認するとよい。

## 参考資料

- **Win32 ウィンドウ/入力層(W2)**: WezTerm(Rust, MIT)— 独自ウィンドウ層を
  持つ GPU ターミナル。`CreateWindowExW`・メッセージループ・`WndProc`・
  キー入力・IME・DPI・クリップボードの実例が読める。`winit`(Rust)— より
  小さく整理された Win32 ウィンドウ実装で、概念リファレンスとして良い。
  いずれも Rust なのでコード流用は不可・考え方の参照のみ。
- **OpenGL on Windows(W3)**: `WGL_ARB_create_context`、glad のロード。
  WGL コンテキスト生成は `winit` / `glad` / GLFW のコードが直接参考になる
  (WezTerm は wgpu 描画なので W3 には不向き)。
- **ConPTY の使い方**: Microsoft Windows Terminal リポジトリ(C++)。
  `CreatePseudoConsole` とパイプ管理の正典。term244 側は実装済みなので
  主に「考え方」の参照。
- **apprt が実装すべき契約**: `src/apprt/embedded.zig`(C-ABI 版・境界が明快)、
  `src/apprt/gtk/`(フル apprt の実例)。

## 難所・リスク

- Win32 のメッセージループとコアのイベントループ(libxev)の統合。
- IME(`WM_IME_*`)対応 — 日本語入力に必須、地味に重い。
- DPI スケーリング(per-monitor v2)。
- `src/os/` に残る Unix 前提コードの個別対応(都度 `builtin.os.tag` で分岐)。
- 規模: W2 が最大。GTK apprt 同等で数千行。全体で数週間〜の独立プロジェクト。
