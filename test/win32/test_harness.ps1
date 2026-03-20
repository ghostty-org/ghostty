# Ghostty Win32 Test Harness
# Usage from WSL: powershell.exe -ExecutionPolicy Bypass -File test_harness.ps1 -Action <action> [args]
#
# Actions:
#   launch      — Start ghostty.exe, output PID
#   screenshot  — Capture ghostty window to PNG file
#   sendkeys    — Send keystrokes to ghostty window
#   sendtext    — Type text into ghostty window
#   check       — Check if ghostty window exists, output title + size
#   close       — Close ghostty window gracefully
#   kill        — Force-kill ghostty process

param(
    [Parameter(Mandatory=$true)]
    [string]$Action,

    [string]$ExePath,
    [string]$Args,
    [string]$OutputPath,
    [string]$Keys,
    [string]$Text,
    [int]$ProcessId,
    [int]$WaitMs = 3000
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Win32Test {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public const uint WM_CLOSE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }
}
"@

function Find-GhosttyWindow {
    param([int]$ProcessId = 0)

    # Use FindWindow by class name — faster and more reliable than
    # EnumWindows with a managed delegate callback.
    $hWnd = [Win32Test]::FindWindow("GhosttyWindow", $null)
    if ($hWnd -eq [IntPtr]::Zero) { return $null }

    # If a PID was specified, verify it matches.
    if ($ProcessId -ne 0) {
        $wpid = [uint32]0
        [Win32Test]::GetWindowThreadProcessId($hWnd, [ref]$wpid) | Out-Null
        if ($wpid -ne $ProcessId) { return $null }
    }

    $sb = New-Object System.Text.StringBuilder 256
    [Win32Test]::GetWindowText($hWnd, $sb, 256) | Out-Null
    return @{ Handle = $hWnd; Title = $sb.ToString(); Pid = $ProcessId }
}

function Invoke-Launch {
    $exe = if ($ExePath) { $ExePath } else {
        # Default: find ghostty.exe relative to this script
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
        $candidate = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDir)) "zig-out\bin\ghostty.exe"
        if (Test-Path $candidate) { $candidate }
        else { throw "ghostty.exe not found. Specify -ExePath." }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    if ($Args) { $psi.Arguments = $Args }
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    Write-Output "PID=$($proc.Id)"

    # Wait for window to appear
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $win = Find-GhosttyWindow -ProcessId $proc.Id
        if ($win) {
            Write-Output "WINDOW_FOUND=true"
            Write-Output "TITLE=$($win.Title)"
            return
        }
    }
    Write-Output "WINDOW_FOUND=false"
}

function Invoke-Screenshot {
    $win = if ($ProcessId) { Find-GhosttyWindow -ProcessId $ProcessId } else { Find-GhosttyWindow }
    if (-not $win) {
        Write-Error "No ghostty window found"
        exit 1
    }

    $hWnd = $win.Handle
    $rect = New-Object Win32Test+RECT
    [Win32Test]::GetWindowRect($hWnd, [ref]$rect) | Out-Null

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top

    if ($width -le 0 -or $height -le 0) {
        Write-Error "Invalid window dimensions: ${width}x${height}"
        exit 1
    }

    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $gfx.GetHdc()

    # PrintWindow with PW_RENDERFULLCONTENT flag (2) for better capture
    [Win32Test]::PrintWindow($hWnd, $hdc, 2) | Out-Null

    $gfx.ReleaseHdc($hdc)
    $gfx.Dispose()

    $outFile = if ($OutputPath) { $OutputPath } else {
        Join-Path $env:TEMP "ghostty_screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
    }
    $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    Write-Output "SCREENSHOT=$outFile"
    Write-Output "SIZE=${width}x${height}"
}

function Invoke-SendKeys {
    $win = if ($ProcessId) { Find-GhosttyWindow -ProcessId $ProcessId } else { Find-GhosttyWindow }
    if (-not $win) {
        Write-Error "No ghostty window found"
        exit 1
    }

    [Win32Test]::SetForegroundWindow($win.Handle) | Out-Null
    Start-Sleep -Milliseconds 100

    if ($Keys) {
        # SendKeys format: {ENTER}, {TAB}, ^c (Ctrl+C), etc.
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
    }
    Write-Output "SENT=$Keys"
}

function Invoke-SendText {
    $win = if ($ProcessId) { Find-GhosttyWindow -ProcessId $ProcessId } else { Find-GhosttyWindow }
    if (-not $win) {
        Write-Error "No ghostty window found"
        exit 1
    }

    [Win32Test]::SetForegroundWindow($win.Handle) | Out-Null
    Start-Sleep -Milliseconds 100

    if ($Text) {
        # Escape special SendKeys characters
        $escaped = $Text -replace '([+^%~{}()\[\]])', '{$1}'
        [System.Windows.Forms.SendKeys]::SendWait($escaped)
    }
    Write-Output "SENT_TEXT=$Text"
}

function Invoke-Check {
    $win = if ($ProcessId) { Find-GhosttyWindow -ProcessId $ProcessId } else { Find-GhosttyWindow }
    if (-not $win) {
        Write-Output "EXISTS=false"
        return
    }

    $hWnd = $win.Handle
    $rect = New-Object Win32Test+RECT
    [Win32Test]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
    $clientRect = New-Object Win32Test+RECT
    [Win32Test]::GetClientRect($hWnd, [ref]$clientRect) | Out-Null

    Write-Output "EXISTS=true"
    Write-Output "TITLE=$($win.Title)"
    Write-Output "PID=$($win.Pid)"
    Write-Output "WINDOW_RECT=$($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)"
    Write-Output "CLIENT_SIZE=$($clientRect.Right)x$($clientRect.Bottom)"
    Write-Output "VISIBLE=$([Win32Test]::IsWindowVisible($hWnd))"
}

function Invoke-Close {
    $win = if ($ProcessId) { Find-GhosttyWindow -ProcessId $ProcessId } else { Find-GhosttyWindow }
    if (-not $win) {
        Write-Output "NO_WINDOW"
        return
    }
    [Win32Test]::PostMessage($win.Handle, [Win32Test]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Write-Output "CLOSED=true"
}

function Invoke-Kill {
    if ($ProcessId) {
        # Use taskkill /T to kill the entire process tree (ghostty + child cmd.exe).
        # Stop-Process only kills the main process, leaving orphaned children.
        & taskkill /PID $ProcessId /T /F 2>$null | Out-Null
        Write-Output "KILLED=$ProcessId"
    } else {
        Get-Process ghostty*  -ErrorAction SilentlyContinue | ForEach-Object {
            & taskkill /PID $_.Id /T /F 2>$null | Out-Null
        }
        Write-Output "KILLED=all"
    }
}

# Dispatch
switch ($Action.ToLower()) {
    "launch"     { Invoke-Launch }
    "screenshot" { Invoke-Screenshot }
    "sendkeys"   { Invoke-SendKeys }
    "sendtext"   { Invoke-SendText }
    "check"      { Invoke-Check }
    "close"      { Invoke-Close }
    "kill"       { Invoke-Kill }
    default      { Write-Error "Unknown action: $Action"; exit 1 }
}
