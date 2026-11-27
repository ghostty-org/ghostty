<#
.SYNOPSIS
  Runs the Zig unit tests for the Windows parts of Ghostty.

.DESCRIPTION
  These cover key translation, the COM and shell helpers, link safety and the
  folder path conversion. Each filter below matches one test by name. The
  full Ghostty test suite is much larger and is not run here.

    powershell -ExecutionPolicy Bypass -File dist\windows\tests\run-unit-tests.ps1 -Zig <path to zig.exe>
#>
[CmdletBinding()]
param(
    [string]$Zig = 'zig'
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..\..')
Push-Location $repo
try {
    $filters = @(
        'letters, digits',
        'left and right variants',
        'unknown keys are unidentified',
        'GUID parsing',
        'copyUtf8',
        'NotifyIconData',
        'only web and mail',
        'windowsPathFromUriPath',
        'virtualKeyOf reverses the mapping'
    )
    $arguments = @('build', 'test', '-Dapp-runtime=win32', '--summary', 'all') + ($filters | ForEach-Object { "-Dtest-filter=$_" })
    & $Zig @arguments
    if ($LASTEXITCODE -ne 0) { throw "Unit tests failed (exit code $LASTEXITCODE)" }
    Write-Host 'Unit tests passed.'
} finally {
    Pop-Location
}
