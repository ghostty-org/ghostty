param(
    [string]$GhosttyExe,
    [int]$TimeoutSeconds = 120,
    [switch]$SkipHeavy
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$tmpDir = Join-Path $repoRoot ".tmp"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$candidates = @()
if ($GhosttyExe) { $candidates += $GhosttyExe }
$candidates += @(
    (Join-Path $repoRoot "zig-out\bin\ghostty.exe"),
    (Join-Path $repoRoot "zig-out-x64\bin\ghostty.exe"),
    (Join-Path $repoRoot "zig-out-release-compat-x64\bin\ghostty.exe"),
    (Join-Path $repoRoot "dist\windows-release-compat\ghostty-windows-x64-compat\ghostty.exe")
)

$ghosttyExe = $candidates |
    Where-Object { $_ -and (Test-Path $_) } |
    Select-Object -First 1

if (-not $ghosttyExe) {
    throw "ghostty.exe not found. Checked: $($candidates -join ', ')"
}

$ghosttyExe = (Resolve-Path $ghosttyExe).Path
$binDir = Split-Path -Parent $ghosttyExe

function Invoke-GhosttyBenchmark {
    param(
        [string]$Name,
        [string]$CmdLine,
        [int]$TimeoutSec
    )

    $errPath = Join-Path $tmpDir ("bench-{0}-stderr.log" -f $Name)
    $outPath = Join-Path $tmpDir ("bench-{0}-stdout.log" -f $Name)
    Remove-Item $errPath, $outPath -ErrorAction SilentlyContinue

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
        $CmdLine
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $ghosttyExe -WorkingDirectory $repoRoot -ArgumentList $args -PassThru -RedirectStandardError $errPath -RedirectStandardOutput $outPath
    $completed = $proc.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()

    $timedOut = -not $completed
    if ($timedOut) {
        try { Stop-Process -Id $proc.Id } catch {}
    }

    $stderr = if (Test-Path $errPath) { Get-Content $errPath -Raw } else { "" }
    $healthEvents = ([regex]::Matches($stderr, "renderer health status change")).Count
    $unhealthyHits = ([regex]::Matches($stderr, "unhealthy")).Count
    $openglHits = ([regex]::Matches($stderr, "loaded OpenGL")).Count

    [PSCustomObject]@{
        benchmark = $Name
        timeout = $timedOut
        exit_code = if ($timedOut) { $null } else { $proc.ExitCode }
        elapsed_ms = [int]$sw.ElapsedMilliseconds
        renderer_health_events = $healthEvents
        unhealthy_hits = $unhealthyHits
        opengl_loaded_hits = $openglHits
        stdout_log = $outPath
        stderr_log = $errPath
    }
}

$oldPath = $env:Path
$oldLog = $env:GHOSTTY_LOG
$oldFcFile = $env:FONTCONFIG_FILE
$oldFcPath = $env:FONTCONFIG_PATH

$env:Path = "$binDir;C:\Windows\System32;C:\Windows"
$env:GHOSTTY_LOG = "stderr"
$env:FONTCONFIG_FILE = "C:\msys64\mingw64\etc\fonts\fonts.conf"
$env:FONTCONFIG_PATH = "C:\msys64\mingw64\etc\fonts"

try {
    $cases = @(
        @{ name = "dir-system32"; cmd = "dir C:\Windows\System32 /s >nul" },
        @{ name = "ascii-flood"; cmd = "for /L %i in (1,1,4000) do @echo ASCII-LINE-%i-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-" },
        @{ name = "number-flood"; cmd = "for /L %i in (1,1,5000) do @echo %random% %random% %random% %random%" }
    )

    if (-not $SkipHeavy) {
        $cases += @{ name = "dir-c-root-heavy"; cmd = "dir C:\ /s >nul" }
    }

    $results = @()
    foreach ($c in $cases) {
        Write-Output ("Running {0}..." -f $c.name)
        $results += Invoke-GhosttyBenchmark -Name $c.name -CmdLine $c.cmd -TimeoutSec $TimeoutSeconds
    }

    $jsonPath = Join-Path $tmpDir "windows-terminal-bench-results.json"
    $results | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonPath

    Write-Output ""
    Write-Output "Benchmark summary:"
    $results | Format-Table benchmark, timeout, exit_code, elapsed_ms, renderer_health_events, unhealthy_hits -AutoSize
    Write-Output ""
    Write-Output "ghostty.exe: $ghosttyExe"
    Write-Output "results json: $jsonPath"
}
finally {
    $env:Path = $oldPath

    if ($null -eq $oldLog) { Remove-Item Env:GHOSTTY_LOG -ErrorAction SilentlyContinue } else { $env:GHOSTTY_LOG = $oldLog }
    if ($null -eq $oldFcFile) { Remove-Item Env:FONTCONFIG_FILE -ErrorAction SilentlyContinue } else { $env:FONTCONFIG_FILE = $oldFcFile }
    if ($null -eq $oldFcPath) { Remove-Item Env:FONTCONFIG_PATH -ErrorAction SilentlyContinue } else { $env:FONTCONFIG_PATH = $oldFcPath }
}
