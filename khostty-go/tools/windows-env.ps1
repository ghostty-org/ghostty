# Dot-source from PowerShell after putting Zig on this session's PATH.
# No installation or persistent environment changes are made.
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This setup is for Windows only.' }
$null = Get-Command zig -ErrorAction Stop
$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
foreach ($artifact in @('zig-out/lib/ghostty-vt.lib', 'zig-out/bin/ghostty-vt.dll')) {
    if (-not (Test-Path "$repoRoot/$artifact")) {
        throw "Missing $artifact; run zig build -Demit-lib-vt -Doptimize=ReleaseFast first."
    }
}
$env:CGO_ENABLED = '1'
$env:CC = '"' + (Join-Path $PSScriptRoot 'zig-cc.cmd') + '"'
# Windows has no rpath: go test executes its binary from a temporary directory.
$env:PATH = (Join-Path $repoRoot 'zig-out/bin') + ';' + $env:PATH
