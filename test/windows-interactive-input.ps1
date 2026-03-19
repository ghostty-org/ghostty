param(
    [switch]$SkipInputCheck,
    [int]$StartupTimeoutSeconds = 20,
    [int]$StabilitySeconds = 8,
    [int]$InputTimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultExe = Join-Path $repoRoot "zig-out\\bin\\ghostty.exe"
$fallbackExe = Join-Path $repoRoot "zig-out-x64\\bin\\ghostty.exe"

$ghosttyExe = if (Test-Path $defaultExe) {
    $defaultExe
} elseif (Test-Path $fallbackExe) {
    $fallbackExe
} else {
    throw "ghostty.exe not found in `zig-out\\bin` or `zig-out-x64\\bin`."
}

$binDir = Split-Path -Parent $ghosttyExe
$tmpDir = Join-Path $repoRoot ".tmp"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$markerFile = Join-Path $tmpDir "ghostty-manual-input.txt"
Remove-Item $markerFile -ErrorAction SilentlyContinue

$args = @(
    "--config-default-files=false",
    "--config-file=",
    "--gtk-single-instance=false",
    "--quit-after-last-window-closed=true",
    "--quit-after-last-window-closed-delay=1s",
    "--wait-after-command=false",
    "--initial-window=true",
    "-e",
    "cmd.exe",
    "/q",
    "/k"
)

$oldPath = $env:Path
$oldGhosttyLog = $env:GHOSTTY_LOG
$env:Path = "$binDir;C:\Windows\System32;C:\Windows"
$env:GHOSTTY_LOG = "stderr"

try {
    $proc = Start-Process -FilePath $ghosttyExe -WorkingDirectory $repoRoot -ArgumentList $args -PassThru

    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    while ((Get-Date) -lt $startupDeadline) {
        $proc.Refresh()
        if ($proc.HasExited) {
            throw "ghostty.exe exited during startup with code $($proc.ExitCode)."
        }

        if ($proc.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 200
    }

    $proc.Refresh()
    if ($proc.MainWindowHandle -eq 0) {
        Stop-Process -Id $proc.Id
        throw "ghostty.exe never created a main window handle."
    }

    $stabilityDeadline = (Get-Date).AddSeconds($StabilitySeconds)
    while ((Get-Date) -lt $stabilityDeadline) {
        Start-Sleep -Milliseconds 250
        $proc.Refresh()
        if ($proc.HasExited) {
            throw "ghostty.exe crashed before stability window elapsed (exit code $($proc.ExitCode))."
        }
    }

    if ($SkipInputCheck) {
        Stop-Process -Id $proc.Id
        Write-Output "PASS: startup stability check succeeded (input check skipped)."
        Write-Output "ghostty.exe: $ghosttyExe"
        exit 0
    }

    Write-Output ""
    Write-Output "Ghostty is running. In the Ghostty window type these commands:"
    Write-Output "  echo interactive hello > `"$markerFile`""
    Write-Output "  exit"
    Write-Output ""
    Write-Output "Waiting up to $InputTimeoutSeconds seconds for marker file + clean exit..."

    $inputDeadline = (Get-Date).AddSeconds($InputTimeoutSeconds)
    while ((Get-Date) -lt $inputDeadline) {
        Start-Sleep -Milliseconds 300
        $proc.Refresh()

        $haveMarker = Test-Path $markerFile
        if ($haveMarker -and $proc.HasExited) { break }
        if ($proc.HasExited -and -not $haveMarker) {
            throw "ghostty.exe exited before marker file was created (exit code $($proc.ExitCode))."
        }
    }

    $proc.Refresh()
    if (-not (Test-Path $markerFile)) {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id
        }
        throw "Marker file was not created in time: $markerFile"
    }

    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id
        throw "Marker file exists but ghostty.exe did not exit. Did you run 'exit'?"
    }

    if ($proc.ExitCode -ne 0) {
        throw "ghostty.exe exited with code $($proc.ExitCode)."
    }

    $content = (Get-Content $markerFile -Raw).Trim()
    if ($content -ne "interactive hello") {
        throw "Unexpected marker file content: '$content'"
    }

    Write-Output "PASS: interactive input smoke test succeeded."
    Write-Output "ghostty.exe: $ghosttyExe"
    Write-Output "marker file: $markerFile"
}
finally {
    $env:Path = $oldPath

    if ($null -eq $oldGhosttyLog) {
        Remove-Item Env:GHOSTTY_LOG -ErrorAction SilentlyContinue
    } else {
        $env:GHOSTTY_LOG = $oldGhosttyLog
    }
}
