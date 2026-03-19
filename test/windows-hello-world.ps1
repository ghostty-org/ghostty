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

$markerFile = Join-Path $tmpDir "ghostty-hello-world.txt"
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
    "/d",
    "/c",
    "echo hello world > `"$markerFile`""
)

$oldPath = $env:Path
$env:Path = "$binDir;C:\Windows\System32;C:\Windows"

try {
    $proc = Start-Process -FilePath $ghosttyExe -ArgumentList $args -PassThru
    $null = $proc.WaitForExit(20000)
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id
        throw "ghostty.exe did not exit within timeout."
    }

    if ($proc.ExitCode -ne 0) {
        throw "ghostty.exe exited with code $($proc.ExitCode)."
    }

    if (-not (Test-Path $markerFile)) {
        throw "Marker file was not created: $markerFile"
    }

    $content = (Get-Content $markerFile -Raw).Trim()
    if ($content -ne "hello world") {
        throw "Unexpected marker file content: '$content'"
    }

    Write-Output "PASS: hello world smoke test succeeded."
    Write-Output "ghostty.exe: $ghosttyExe"
    Write-Output "marker file: $markerFile"
}
finally {
    $env:Path = $oldPath
}
