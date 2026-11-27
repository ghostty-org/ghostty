<#
.SYNOPSIS
  Packs the built Windows version of Ghostty into a zip that can be installed
  on another computer.

.DESCRIPTION
  Build first (see build.ps1), then:
    powershell -ExecutionPolicy Bypass -File dist\windows\package.ps1

  The zip holds ghostty.exe, its resources and install.ps1. On the other
  computer, unzip it and run install.ps1. Nothing else needs to be installed.

.PARAMETER OutDir
  Where the zip is written. Defaults to dist\windows\out.
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here '..\..')
if (-not $OutDir) { $OutDir = Join-Path $here 'out' }

$build = Join-Path $repo 'zig-out'
if (-not (Test-Path (Join-Path $build 'bin\ghostty.exe'))) { throw "Build output not found in $build. Build Ghostty first." }

$stage = Join-Path $OutDir 'ghostty-windows-x64'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $stage 'bin') | Out-Null

Copy-Item (Join-Path $build 'bin\ghostty.exe') (Join-Path $stage 'bin')
Copy-Item (Join-Path $build 'share') $stage -Recurse
foreach ($file in 'install.ps1', 'uninstall.ps1', 'README.md') { Copy-Item (Join-Path $here $file) $stage }

$zip = Join-Path $OutDir 'ghostty-windows-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Wrote $zip"
