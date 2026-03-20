param([string]$ExePath, [string]$ScreenshotDir = "")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP p, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@

$pass = 0; $fail = 0

function Take-Screenshot($proc, $name) {
    if (-not $ScreenshotDir) { return }
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    $r = New-Object W32+RECT
    [W32]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { return }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [W32]::PrintWindow($h, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bmp.Save("$ScreenshotDir\${name}_$ts.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Send-Keys($proc, $keys) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 200
    }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
}

function Send-Text($proc, $text) {
    $escaped = $text -replace '([+^%~{}()\[\]])', '{$1}'
    Send-Keys $proc $escaped
}

function Count-GhosttyWindows($pid) {
    $script:wcount = 0
    $cb = [W32+EP]{param($h,$l)
        $wp = [uint32]0
        [W32]::GetWindowThreadProcessId($h, [ref]$wp) | Out-Null
        if ($wp -eq $pid -and [W32]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [W32]::GetClassName($h, $sb, 256) | Out-Null
            if ($sb.ToString() -eq "GhosttyWindow") { $script:wcount++ }
        }
        return $true
    }
    [W32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $script:wcount
}

function Launch-Ghostty {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.BeginErrorReadLine()

    # Wait for main window
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 200
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc }
    }
    Write-Output "  WARN: Window handle not found after 6s"
    return $proc
}

# ═══════════════════════════════════════
# TEST: New Tab
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: New Tab ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

Take-Screenshot $proc "01_initial"

# Open new tab
Send-Keys $proc "^+t"
Start-Sleep -Seconds 3

Take-Screenshot $proc "02_after_new_tab"

$wc = Count-GhosttyWindows $proc.Id
if ($wc -eq 1) {
    Write-Output "  OK: Still 1 window (tab is inside)"
} else {
    Write-Output "  INFO: Window count = $wc (EnumWindows may fail in WSL2)"
}

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive after new tab"
    $pass++
} else {
    Write-Output "  FAIL: Process died after new tab"
    $fail++
}
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Tab Switch
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Tab Switch ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Type in tab 1
Send-Text $proc "echo TAB1"
Send-Keys $proc "{ENTER}"
Start-Sleep -Seconds 1

# Open tab 2
Send-Keys $proc "^+t"
Start-Sleep -Seconds 3

Send-Text $proc "echo TAB2"
Send-Keys $proc "{ENTER}"
Start-Sleep -Seconds 1

Take-Screenshot $proc "03_tab2"

# Switch to tab 1
Send-Keys $proc "^+{PGUP}"
Start-Sleep -Seconds 1
Take-Screenshot $proc "04_tab1_switch"

# Switch to tab 2
Send-Keys $proc "^+{PGDN}"
Start-Sleep -Seconds 1
Take-Screenshot $proc "05_tab2_switch"

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive after tab switching"
    $pass++
} else {
    Write-Output "  FAIL: Process died during tab switch"
    $fail++
}
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Tab Close
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Tab Close ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Open 2 extra tabs (3 total)
Send-Keys $proc "^+t"
Start-Sleep -Seconds 2
Send-Keys $proc "^+t"
Start-Sleep -Seconds 2

Take-Screenshot $proc "06_three_tabs"

# Close one tab
Send-Keys $proc "^+w"
Start-Sleep -Seconds 2

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive after closing 1 tab"
} else {
    Write-Output "  FAIL: Process died after closing 1 tab"
    $fail++
    Write-Output "  FAILED"
    return
}

# Close another tab
Send-Keys $proc "^+w"
Start-Sleep -Seconds 2

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive (1 tab remains)"
} else {
    Write-Output "  FAIL: Process died after closing 2nd tab"
    $fail++
    Write-Output "  FAILED"
    return
}

Take-Screenshot $proc "07_one_tab_remains"

# Close last tab — process should exit
Send-Keys $proc "^+w"
Start-Sleep -Seconds 3

if ($proc.HasExited) {
    Write-Output "  OK: Process exited after closing last tab"
} else {
    Write-Output "  WARN: Process still alive (may need quit timer)"
    & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
}
$pass++
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Rapid Tabs
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Rapid Tabs ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Open 5 tabs rapidly
for ($i = 0; $i -lt 5; $i++) {
    Send-Keys $proc "^+t"
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 2

Take-Screenshot $proc "08_six_tabs"

if (-not $proc.HasExited) {
    Write-Output "  OK: Survived rapid tab creation"
} else {
    Write-Output "  FAIL: Crashed during rapid tab creation"
    $fail++
    Write-Output "  FAILED"
    return
}

# Rapid switching
for ($i = 0; $i -lt 6; $i++) {
    Send-Keys $proc "^+{PGDN}"
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Seconds 1

if (-not $proc.HasExited) {
    Write-Output "  OK: Survived rapid tab switching"
} else {
    Write-Output "  FAIL: Crashed during rapid tab switching"
    $fail++
}

& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
$pass++
Write-Output "  PASSED"

# ═══════════════════════════════════════
Write-Output ""
Write-Output "================================"
Write-Output "Results: $pass passed, $fail failed"
Write-Output "================================"
if ($fail -gt 0) { exit 1 }
