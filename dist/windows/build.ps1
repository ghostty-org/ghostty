<#
.SYNOPSIS
  Builds the Windows version of Ghostty, runs the tests, and installs it.

.DESCRIPTION
    powershell -ExecutionPolicy Bypass -File dist\windows\build.ps1 -Zig C:\path\to\zig.exe

  Zig 0.17.0 is required. Pass -SkipTests to build and install without
  running the tests, and -NoInstall to stop after the tests.
#>
[CmdletBinding()]
param(
    [string]$Zig = 'zig',
    [switch]$SkipTests,
    [switch]$NoInstall
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here '..\..')

Push-Location $repo
try {
    Write-Host '== Building'
    & $Zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast -Dapp-runtime=win32
    if ($LASTEXITCODE -ne 0) { throw "The build failed (exit code $LASTEXITCODE)" }

    if (-not $SkipTests) {
        Write-Host '== Unit tests'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'tests\run-unit-tests.ps1') -Zig $Zig
        if ($LASTEXITCODE -ne 0) { throw 'The unit tests failed' }

        Write-Host '== End to end tests (these open Ghostty windows for a minute or two)'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'tests\run-tests.ps1')
        if ($LASTEXITCODE -ne 0) { throw "$LASTEXITCODE end to end test(s) failed" }
    }

    if (-not $NoInstall) {
        Write-Host '== Installing'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'install.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'The install failed' }
    }
} finally {
    Pop-Location
}
