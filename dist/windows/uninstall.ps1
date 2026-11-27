<#
.SYNOPSIS
  Removes what install.ps1 added: the program, its resources, the `ghostty`
  command and the Start menu shortcut. Settings in your Ghostty config
  folder are left alone.
#>
[CmdletBinding()]
param(
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

if (-not $InstallDir) { $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$installedExe = Join-Path $InstallDir 'bin\ghostty.exe'
$running = Get-Process ghostty -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $installedExe) }
if ($running) { throw "Ghostty is running from $installedExe. Close it and run this again." }

# install.ps1 records where it put the command and shortcut.
$settings = @{}
$configFile = Join-Path $InstallDir 'uninstall.config'
if (Test-Path $configFile) {
    Get-Content $configFile | ForEach-Object {
        $name, $value = $_ -split '=', 2
        if ($name) { $settings[$name] = $value }
    }
}

if ($settings.ShimDir) {
    $shim = Join-Path $settings.ShimDir 'ghostty.cmd'
    # Only delete a command that points at this install.
    if ((Test-Path $shim) -and ((Get-Content $shim -Raw) -match [regex]::Escape($installedExe))) {
        Remove-Item $shim -Force
    }
}
if ($settings.StartMenuDir) {
    Remove-Item (Join-Path $settings.StartMenuDir 'Ghostty.lnk') -Force -ErrorAction SilentlyContinue
}

# The script is running from inside the folder, so it cannot delete itself
# while it runs. Remove everything else, then schedule the folder's removal.
Remove-Item (Join-Path $InstallDir 'bin') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $InstallDir 'share') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $configFile -Force -ErrorAction SilentlyContinue
Start-Process cmd.exe -ArgumentList '/c', "ping 127.0.0.1 -n 3 >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden

Write-Host "Ghostty was removed from $InstallDir"
