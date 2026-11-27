<#
.SYNOPSIS
  Installs the Windows build of Ghostty for the current user.

.DESCRIPTION
  Copies ghostty.exe and its resources to a per-user folder, adds a
  `ghostty` command that works from cmd and PowerShell, and adds a Start menu
  shortcut. It does not touch the registry, the PATH variable or the default
  terminal setting, and it needs no administrator rights.

  Run it from the repository after building:
    zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast -Dapp-runtime=win32
    powershell -ExecutionPolicy Bypass -File dist\windows\install.ps1

.PARAMETER SourceDir
  The build output folder, which holds bin\ and share\.
.PARAMETER InstallDir
  Where Ghostty is installed. The program goes in bin\ and its resources in
  share\, which is the layout Ghostty looks for next to itself.
.PARAMETER ShimDir
  A folder that is already on PATH, where the `ghostty` command is placed.
.PARAMETER StartMenuDir
  Where the Start menu shortcut is placed.
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$InstallDir,
    [string]$ShimDir,
    [string]$StartMenuDir,
    [switch]$NoShim,
    [switch]$NoStartMenu
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not set yet in parameter defaults when run with -File, so the
# defaults are filled in here.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# A release package keeps bin and share next to this script. In the
# repository they are in zig-out.
if (-not $SourceDir) {
    $SourceDir = if (Test-Path (Join-Path $scriptDir 'bin\ghostty.exe')) { $scriptDir } else { Join-Path $scriptDir '..\..\zig-out' }
}
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Ghostty' }
if (-not $ShimDir) { $ShimDir = Join-Path $env:USERPROFILE '.local\bin' }
if (-not $StartMenuDir) { $StartMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }

$sourceExe = Join-Path $SourceDir 'bin\ghostty.exe'
$sourceShare = Join-Path $SourceDir 'share'
if (-not (Test-Path $sourceExe)) { throw "Build output not found: $sourceExe. Build Ghostty first." }
if (-not (Test-Path (Join-Path $sourceShare 'terminfo\ghostty.terminfo'))) { throw "Resources not found in $sourceShare." }

$installedExe = Join-Path $InstallDir 'bin\ghostty.exe'

# A running copy keeps its file locked, so say so instead of failing halfway.
$running = Get-Process ghostty -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $installedExe) }
if ($running) { throw "Ghostty is running from $installedExe. Close it and run this again." }

New-Item -ItemType Directory -Force (Join-Path $InstallDir 'bin') | Out-Null
Copy-Item $sourceExe $installedExe -Force

# Resources are replaced as a whole so files removed from the build do not
# linger. The pkg-config files are for building against libghostty, not for
# running it.
$installedShare = Join-Path $InstallDir 'share'
if (Test-Path $installedShare) { Remove-Item $installedShare -Recurse -Force }
Copy-Item $sourceShare $installedShare -Recurse -Force
Remove-Item (Join-Path $installedShare 'pkgconfig') -Recurse -Force -ErrorAction SilentlyContinue

Copy-Item (Join-Path $scriptDir 'uninstall.ps1') (Join-Path $InstallDir 'uninstall.ps1') -Force
Set-Content (Join-Path $InstallDir 'uninstall.config') -Value "ShimDir=$ShimDir`nStartMenuDir=$StartMenuDir" -Encoding ASCII

if (-not $NoShim) {
    New-Item -ItemType Directory -Force $ShimDir | Out-Null
    # Starting the terminal must return the prompt at once, so it is started
    # detached. CLI actions such as `ghostty +version` run in place instead,
    # so their output and exit code reach the caller.
    $shim = @"
@echo off
set "GHOSTTY_EXE=$installedExe"
if "%~1"=="" goto window
set "GHOSTTY_FIRST=%~1"
if "%GHOSTTY_FIRST:~0,1%"=="+" goto action
:window
start "" "%GHOSTTY_EXE%" %*
exit /b 0
:action
"%GHOSTTY_EXE%" %*
exit /b %ERRORLEVEL%
"@
    Set-Content (Join-Path $ShimDir 'ghostty.cmd') -Value $shim -Encoding ASCII

    $onPath = ($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $ShimDir.TrimEnd('\') }
    if (-not $onPath) { Write-Warning "$ShimDir is not on PATH, so the ghostty command will not be found until you add it." }
}

if (-not $NoStartMenu) {
    New-Item -ItemType Directory -Force $StartMenuDir | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $StartMenuDir 'Ghostty.lnk'))
    $link.TargetPath = $installedExe
    $link.WorkingDirectory = $env:USERPROFILE
    $link.Description = 'Ghostty terminal'
    $link.Save()
}

Write-Host "Installed Ghostty to $InstallDir"
if (-not $NoShim) { Write-Host "Command:    $(Join-Path $ShimDir 'ghostty.cmd')  (run `ghostty` in a new terminal)" }
if (-not $NoStartMenu) { Write-Host "Start menu: $(Join-Path $StartMenuDir 'Ghostty.lnk')" }
Write-Host "To remove it: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'uninstall.ps1')`""
