param(
    [switch]$ManualUnfocus,
    [int]$StartupTimeoutSeconds = 20,
    [int]$SampleIntervalSeconds = 2,
    [int]$UnfocusedSamples = 3,
    [string]$GhosttyExe
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

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class Win32GhosttyTest {
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
'@

function Test-RectOverlap {
    param(
        [int]$LeftA,
        [int]$TopA,
        [int]$RightA,
        [int]$BottomA,
        [int]$LeftB,
        [int]$TopB,
        [int]$RightB,
        [int]$BottomB
    )

    return (
        $LeftA -lt $RightB -and
        $RightA -gt $LeftB -and
        $TopA -lt $BottomB -and
        $BottomA -gt $TopB
    )
}

function Get-WindowHash {
    param(
        [IntPtr]$Hwnd,
        [int]$TrimPixels = 24
    )

    $rect = New-Object Win32GhosttyTest+RECT
    if (-not [Win32GhosttyTest]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw "GetWindowRect failed for HWND $Hwnd"
    }

    $width = [Math]::Max(1, $rect.Right - $rect.Left)
    $height = [Math]::Max(1, $rect.Bottom - $rect.Top)

    $captureLeft = $rect.Left + $TrimPixels
    $captureTop = $rect.Top + $TrimPixels
    $captureWidth = $width - ($TrimPixels * 2)
    $captureHeight = $height - ($TrimPixels * 2)

    if ($captureWidth -lt 1 -or $captureHeight -lt 1) {
        $captureLeft = $rect.Left
        $captureTop = $rect.Top
        $captureWidth = $width
        $captureHeight = $height
    }

    $captureWidth = [Math]::Max(1, $captureWidth)
    $captureHeight = [Math]::Max(1, $captureHeight)

    $bitmap = New-Object System.Drawing.Bitmap($captureWidth, $captureHeight)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen(
        $captureLeft,
        $captureTop,
        0,
        0,
        (New-Object System.Drawing.Size($captureWidth, $captureHeight))
    )
    $graphics.Dispose()

    $stream = New-Object System.IO.MemoryStream
    try {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return [System.BitConverter]::ToString($sha.ComputeHash($stream.ToArray())).Replace("-", "")
    }
    finally {
        $stream.Dispose()
        $bitmap.Dispose()
    }
}

$args = @(
    "--config-default-files=false",
    "--config-file=",
    "--gtk-single-instance=false",
    "--quit-after-last-window-closed=true",
    "--quit-after-last-window-closed-delay=1s",
    "--wait-after-command=false",
    "--initial-window=true",
    "--cursor-style-blink=false",
    "-e",
    "cmd.exe",
    "/d",
    "/c",
    "for /L %i in (1,1,90) do @echo unfocused-render-line-%i && @ping -n 2 127.0.0.1 >nul"
)

$oldPath = $env:Path
$env:Path = "$binDir;C:\Windows\System32;C:\Windows"

$ghosttyProc = $null
$focusStealer = $null
$focusStealerForm = $null

function Start-FocusStealerWindow {
    param([IntPtr]$AvoidHwnd)

    $avoidRect = New-Object Win32GhosttyTest+RECT
    if (-not [Win32GhosttyTest]::GetWindowRect($AvoidHwnd, [ref]$avoidRect)) {
        throw "GetWindowRect failed while creating focus-stealing window."
    }

    $formWidth = 220
    $formHeight = 120
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $positions = @(
        @{ Left = $screen.Left + 12; Top = $screen.Top + 12 },
        @{ Left = $screen.Right - $formWidth - 12; Top = $screen.Top + 12 },
        @{ Left = $screen.Left + 12; Top = $screen.Bottom - $formHeight - 12 },
        @{ Left = $screen.Right - $formWidth - 12; Top = $screen.Bottom - $formHeight - 12 }
    )

    $selectedPos = $positions[0]
    foreach ($pos in $positions) {
        $overlap = Test-RectOverlap `
            -LeftA $pos.Left `
            -TopA $pos.Top `
            -RightA ($pos.Left + $formWidth) `
            -BottomA ($pos.Top + $formHeight) `
            -LeftB $avoidRect.Left `
            -TopB $avoidRect.Top `
            -RightB $avoidRect.Right `
            -BottomB $avoidRect.Bottom

        if (-not $overlap) {
            $selectedPos = $pos
            break
        }
    }

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Ghostty Focus Stealer"
        $form.Width = $formWidth
        $form.Height = $formHeight
        $form.TopMost = $true
        $form.ShowInTaskbar = $true
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Left = $selectedPos.Left
        $form.Top = $selectedPos.Top
        $form.Show()
        $form.Activate()
        Start-Sleep -Milliseconds 300
        if ($form.Handle -ne [IntPtr]::Zero) {
            $script:focusStealerForm = $form
            return $form.Handle
        }
        $form.Close()
        $form.Dispose()
    }
    catch {}

    return [IntPtr]::Zero
}

try {
    $ghosttyProc = Start-Process -FilePath $ghosttyExe -WorkingDirectory $repoRoot -ArgumentList $args -PassThru

    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    while ((Get-Date) -lt $startupDeadline) {
        $ghosttyProc.Refresh()
        if ($ghosttyProc.HasExited) {
            throw "ghostty.exe exited during startup with code $($ghosttyProc.ExitCode)."
        }

        if ($ghosttyProc.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 200
    }

    $ghosttyProc.Refresh()
    if ($ghosttyProc.MainWindowHandle -eq 0) {
        throw "ghostty.exe never created a main window handle."
    }

    $ghosttyHwnd = [IntPtr]$ghosttyProc.MainWindowHandle

    $focusedHashA = Get-WindowHash -Hwnd $ghosttyHwnd
    Start-Sleep -Seconds $SampleIntervalSeconds
    $focusedHashB = Get-WindowHash -Hwnd $ghosttyHwnd

    if ($focusedHashA -eq $focusedHashB) {
        throw "Focused baseline did not change. The output workload may be stalled."
    }

    if ($ManualUnfocus) {
        Write-Output "Bring another window to the foreground, then press Enter."
        [void](Read-Host)
    } else {
        $focusStealer = Start-FocusStealerWindow -AvoidHwnd $ghosttyHwnd
        if ($focusStealer -eq [IntPtr]::Zero) {
            throw "Unable to open a focus-stealing window automatically. Re-run with -ManualUnfocus."
        }

        [void][Win32GhosttyTest]::ShowWindow($focusStealer, 5)
        [void][Win32GhosttyTest]::SetForegroundWindow($focusStealer)
        Start-Sleep -Milliseconds 600
    }

    $foreground = [Win32GhosttyTest]::GetForegroundWindow()
    if ($foreground -eq $ghosttyHwnd) {
        throw "Ghostty still appears focused. Re-run with -ManualUnfocus and switch away before pressing Enter."
    }

    $hashes = @()
    for ($i = 0; $i -lt $UnfocusedSamples; $i++) {
        Start-Sleep -Seconds $SampleIntervalSeconds
        $ghosttyProc.Refresh()
        if ($ghosttyProc.HasExited) {
            throw "ghostty.exe exited before unfocused sampling finished (code $($ghosttyProc.ExitCode))."
        }
        $hashes += Get-WindowHash -Hwnd $ghosttyHwnd
    }

    $distinct = ($hashes | Select-Object -Unique).Count
    if ($distinct -lt 2) {
        throw "FAIL: window content stayed static while unfocused ($UnfocusedSamples samples)."
    }

    Write-Output "PASS: unfocused redraw test succeeded."
    Write-Output "ghostty.exe: $ghosttyExe"
    Write-Output "focused hashes differ: $focusedHashA != $focusedHashB"
    Write-Output "distinct unfocused hashes: $distinct / $UnfocusedSamples"
}
finally {
    if ($focusStealerForm) {
        try { $focusStealerForm.Close() } catch {}
        try { $focusStealerForm.Dispose() } catch {}
    }
    if ($ghosttyProc -and -not $ghosttyProc.HasExited) {
        try { Stop-Process -Id $ghosttyProc.Id } catch {}
    }
    $env:Path = $oldPath
}
