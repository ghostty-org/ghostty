<#
.SYNOPSIS
  End to end tests for the Windows build of Ghostty.

.DESCRIPTION
  Starts real Ghostty windows and drives them with window messages, then
  checks what they did by reading the window layout and the files a typed
  command creates. It needs no keyboard focus, so it can run while you use the
  machine, but each test opens a window for a few seconds.

  Plain F-keys are bound to actions through --keybind, because posted key
  messages carry no Ctrl or Shift state.

    powershell -ExecutionPolicy Bypass -File dist\windows\tests\run-tests.ps1
    powershell -ExecutionPolicy Bypass -File dist\windows\tests\run-tests.ps1 -Filter tabs
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [string]$Filter = '*'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Exe) { $Exe = Join-Path $scriptDir '..\..\..\zig-out\bin\ghostty.exe' }
$Exe = (Resolve-Path $Exe).Path

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class GT {
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    // The top-level windows of one class that belong to a process.
    public static List<IntPtr> WindowsOf(uint pid, string cls) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner != pid) return true;
            var name = new StringBuilder(64);
            GetClassName(h, name, 64);
            if (name.ToString() == cls) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }

    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public Rc Monitor; public Rc Work; public uint Flags; }
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);

    // Report real pixels instead of the scaled ones a program unaware of
    // display scaling is shown.
    public static void MakeDpiAware() { SetThreadDpiAwarenessContext((IntPtr)(-4)); }

    // The usable area of the screen a window is on, in real pixels.
    public static int[] WorkAreaOf(IntPtr h) {
        var info = new MonitorInfo(); info.Size = Marshal.SizeOf(typeof(MonitorInfo));
        GetMonitorInfoW(MonitorFromWindow(h, 2), ref info);
        return new[] { info.Work.L, info.Work.T, info.Work.R, info.Work.B };
    }

    // Left, top, right and bottom of a window on the screen.
    public static int[] RectOf(IntPtr h) {
        Rc r; GetWindowRect(h, out r);
        return new[] { r.L, r.T, r.R, r.B };
    }

    // A window of the given class anywhere inside another, or zero.
    public static IntPtr FindByClass(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var name = new StringBuilder(64);
            GetClassName(h, name, 64);
            if (name.ToString() == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rc r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rc r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Pt p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);

    // Where the client area starts inside the whole window, in pixels.
    public static int[] ClientOffset(IntPtr h) {
        Rc w; GetWindowRect(h, out w);
        var origin = new Pt();
        ClientToScreen(h, ref origin);
        return new[] { origin.X - w.L, origin.Y - w.T, w.R - w.L, w.B - w.T };
    }

    [StructLayout(LayoutKind.Sequential)] public struct Rc { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X, Y; }

    public class Kid { public bool Visible; public int X, Y, W, H; }

    // The terminals inside a window, positioned relative to its client area.
    public static List<Kid> Kids(IntPtr top) {
        var origin = new Pt();
        ClientToScreen(top, ref origin);
        var result = new List<Kid>();
        EnumChildWindows(top, (h, l) => {
            Rc r; GetWindowRect(h, out r);
            result.Add(new Kid { Visible = IsWindowVisible(h), X = r.L - origin.X, Y = r.T - origin.Y, W = r.R - r.L, H = r.B - r.T });
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // Where the window's top left corner is on the screen.
    public static int[] WindowOrigin(IntPtr h) {
        Rc w; GetWindowRect(h, out w);
        return new[] { w.L, w.T };
    }

    public static int[] Client(IntPtr top) {
        Rc r; GetClientRect(top, out r);
        return new[] { r.R, r.B };
    }

    // The first terminal window inside a top-level window.
    public static IntPtr FirstChild(IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => { found = h; return false; }, IntPtr.Zero);
        return found;
    }

    public static IntPtr MakeLParam(int x, int y) {
        return (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF));
    }
}
'@

$results = New-Object System.Collections.Generic.List[object]

# Only the build under test is stopped. A Ghostty installed elsewhere, which
# may well be the terminal this script is running in, is left alone.
function Stop-TestGhostty {
    Get-Process ghostty -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and ($_.Path -ieq $Exe) } |
        Stop-Process -Force
}

function Start-Ghostty([string[]]$GhosttyArgs = @()) {
    Stop-TestGhostty
    # Extra settings for every test, such as --shell-integration=none to check that a test notices the difference.
    if ($env:GHOSTTY_TEST_EXTRA_ARGS) { $GhosttyArgs = @($GhosttyArgs) + ($env:GHOSTTY_TEST_EXTRA_ARGS -split ' ') }
    $params = @{ FilePath = $Exe; PassThru = $true }
    if ($GhosttyArgs.Count -gt 0) { $params.ArgumentList = ($GhosttyArgs -join ' ') }
    $p = Start-Process @params
    # Wait for the window rather than sleeping a fixed time.
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Milliseconds 100
        $p.Refresh()
        if ($p.HasExited) { throw "Ghostty exited at startup with code $($p.ExitCode)" }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero -and [GT]::Kids($p.MainWindowHandle).Count -ge 1) { break }
    }
    # The terminal ignores input until it has finished starting. Its shell
    # sets the window title once it is up, so wait for that.
    for ($i = 0; $i -lt 150; $i++) {
        $p.Refresh()
        if ($p.MainWindowTitle -and $p.MainWindowTitle -ne 'Ghostty') { break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 400
    $p.Refresh()
    return $p
}

function Send-Key($p, [int]$vk, [int]$settleMs = 1200) {
    $scan = [GT]::MapVirtualKeyW($vk, 0)
    $lparam = [int64](1 + ($scan * 65536))
    [void][GT]::PostMessageW($p.MainWindowHandle, 0x100, [IntPtr]$vk, [IntPtr]$lparam)
    Start-Sleep -Milliseconds 50
    [void][GT]::PostMessageW($p.MainWindowHandle, 0x101, [IntPtr]$vk, [IntPtr]($lparam + 3221225472))
    Start-Sleep -Milliseconds $settleMs
}

function Send-Text($p, [string]$text) {
    foreach ($ch in $text.ToCharArray()) {
        $vk = switch ($ch) {
            ' ' { 0x20 }
            '.' { 0xBE }
            ',' { 0xBC }
            '-' { 0xBD }
            '/' { 0xBF }
            ';' { 0xBA }
            '=' { 0xBB }
            default { [int][char]::ToUpper($ch) }
        }
        Send-Key $p $vk 40
    }
}

function Send-Mouse($p, [uint32]$message, [int]$x, [int]$y, [int]$settleMs = 600) {
    [void][GT]::PostMessageW($p.MainWindowHandle, $message, [IntPtr]::Zero, [GT]::MakeLParam($x, $y))
    Start-Sleep -Milliseconds $settleMs
}

function Get-Kids($p) { [GT]::Kids($p.MainWindowHandle) }
function Get-Visible($p) { Get-Kids $p | Where-Object { $_.Visible } }

Add-Type -AssemblyName System.Drawing

# A picture of the whole window as it is drawn, children included.
function Get-WindowImage($p) {
    $info = [GT]::ClientOffset($p.MainWindowHandle)
    $bitmap = New-Object System.Drawing.Bitmap $info[2], $info[3]
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $dc = $g.GetHdc()
    [void][GT]::PrintWindow($p.MainWindowHandle, $dc, 2)
    $g.ReleaseHdc($dc)
    $g.Dispose()
    return [pscustomobject]@{ Bitmap = $bitmap; OffsetX = $info[0]; OffsetY = $info[1] }
}

# How many pixels in a column of the client area differ from a color.
function Count-ColumnDiffs($image, [int]$clientX, [int]$clientHeight, $rgb) {
    $count = 0
    for ($y = 0; $y -lt $clientHeight; $y += 2) {
        $c = $image.Bitmap.GetPixel($image.OffsetX + $clientX, $image.OffsetY + $y)
        if ([math]::Abs($c.R - $rgb[0]) + [math]::Abs($c.G - $rgb[1]) + [math]::Abs($c.B - $rgb[2]) -gt 30) { $count++ }
    }
    return $count
}

function Stop-Ghostty($p) {
    Stop-TestGhostty
}

# Key codes for the F-keys the tests bind.
$F1 = 0x70; $F2 = 0x71; $F3 = 0x72; $F5 = 0x74; $F6 = 0x75; $F7 = 0x76; $F8 = 0x77; $F9 = 0x78; $F10 = 0x79
$binds = @(
    '--keybind=f1=new_tab', '--keybind=f2=new_split:right', '--keybind=f3=new_split:down',
    '--keybind=f5=close_surface', '--keybind=f6=next_tab', '--keybind=f7=toggle_split_zoom',
    '--keybind=f8=previous_tab', '--keybind=f9=goto_tab:1', '--keybind=f10=close_tab:this'
)

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Name -notlike "*$Filter*") { return }
    $started = Get-Date
    try {
        & $Body
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Detail = '' })
        Write-Host ("PASS  {0}  ({1:N1}s)" -f $Name, ((Get-Date) - $started).TotalSeconds)
    } catch {
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Detail = $_.Exception.Message })
        Write-Host ("FAIL  {0}  - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    } finally {
        Stop-Ghostty $null
    }
}

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# ----------------------------------------------------------------------------

Test-Case 'cli: +version prints and exits 0' {
    $out = & $Exe +version 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"
    Assert ($out -match 'Ghostty') "output was: $out"
}

Test-Case 'cli: unknown action fails' {
    $run = Start-Process $Exe -ArgumentList '+nosuchaction' -Wait -PassThru -WindowStyle Hidden
    Assert ($run.ExitCode -ne 0) 'expected a non-zero exit code'
}

Test-Case 'window: opens with a terminal filling it' {
    $p = Start-Ghostty
    $kids = Get-Kids $p
    Assert ($kids.Count -eq 1) "expected 1 terminal, found $($kids.Count)"
    $client = [GT]::Client($p.MainWindowHandle)
    Assert ($kids[0].W -eq $client[0] -and $kids[0].H -eq $client[1]) "terminal $($kids[0].W)x$($kids[0].H) does not fill client $($client -join 'x')"
}

Test-Case 'window: stays idle without using CPU' {
    $p = Start-Ghostty
    $before = $p.TotalProcessorTime.TotalSeconds
    Start-Sleep -Seconds 3
    $p.Refresh()
    $used = $p.TotalProcessorTime.TotalSeconds - $before
    Assert ($used -lt 0.5) "used $used s of CPU in 3 s while idle"
}

Test-Case 'typing: a typed command runs in the shell' {
    # A new shell starts in the user's profile folder.
    $name = 'ghosttytest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $env:USERPROFILE $name
    $p = Start-Ghostty
    try {
        Send-Text $p "mkdir $name"
        Send-Key $p 0x0D 2000
        Assert (Test-Path $dir) "directory $name was not created"
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'config: window size comes from the config' {
    $p = Start-Ghostty @('--window-width=100', '--window-height=30')
    $client = [GT]::Client($p.MainWindowHandle)
    Assert ($client[0] -ne 984 -or $client[1] -ne 601) "size stayed at the default $($client -join 'x')"
}

Test-Case 'config: maximize' {
    $p = Start-Ghostty @('--maximize=true')
    Assert ([GT]::IsZoomed($p.MainWindowHandle)) 'window is not maximized'
}

Test-Case 'config: fullscreen removes the title bar' {
    $p = Start-Ghostty @('--fullscreen=true')
    $style = [GT]::GetWindowLong($p.MainWindowHandle, -16)
    Assert (($style -band 0xC00000) -eq 0) 'the title bar is still there'
    $client = [GT]::Client($p.MainWindowHandle)
    Assert ($client[0] -ge 1280) "client width $($client[0]) is too small for fullscreen"
}

Test-Case 'tabs: new tab, switching and closing' {
    $p = Start-Ghostty $binds
    Send-Key $p $F1
    $kids = Get-Kids $p
    Assert ($kids.Count -eq 2) "expected 2 terminals after new_tab, found $($kids.Count)"
    Assert (@(Get-Visible $p).Count -eq 1) 'only the new tab should be visible'
    $bar = (@($kids | Where-Object { $_.Visible }) | Select-Object -First 1).Y
    Assert ($bar -gt 20) "tab bar missing, terminal starts at y=$bar"

    Send-Key $p $F6
    $now = @(Get-Visible $p)
    Assert ($now.Count -eq 1) 'next_tab should show exactly one terminal'
    Send-Key $p $F8
    Send-Key $p $F9
    Assert (@(Get-Visible $p).Count -eq 1) 'goto_tab:1 should show exactly one terminal'

    Send-Key $p $F10
    Assert (@(Get-Kids $p).Count -eq 1) 'close_tab should leave one terminal'
    $client = [GT]::Client($p.MainWindowHandle)
    $last = @(Get-Kids $p)[0]
    Assert ($last.Y -le 1 -and $last.H -eq $client[1]) "tab bar should disappear with one tab (y=$($last.Y))"
}

Test-Case 'tabs: closing the last tab quits the app' {
    $p = Start-Ghostty $binds
    Send-Key $p $F10 2500
    $p.Refresh()
    Assert $p.HasExited 'Ghostty is still running'
}

Test-Case 'tabs: input still works after closing a tab' {
    $p = Start-Ghostty $binds
    Send-Key $p $F1
    Send-Key $p $F2
    Send-Key $p $F10
    Send-Key $p $F1
    Assert (@(Get-Kids $p).Count -eq 2) 'new_tab after closing a tab did not work'
}

Test-Case 'tabs: a new tab starts in the folder the shell is in' {
    # cmd does not announce its folder, so Ghostty reads it from the process.
    $name = 'ghosttycwdreal' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $env:USERPROFILE $name
    New-Item -ItemType Directory $dir | Out-Null
    try {
        $p = Start-Ghostty $binds
        Send-Text $p "cd $name"
        Send-Key $p 0x0D 1500
        Send-Key $p $F1 2500
        Send-Text $p 'mkdir marker'
        Send-Key $p 0x0D 2500
        Assert (Test-Path (Join-Path $dir 'marker')) 'the new tab did not start in the shell folder'
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'splits: a new split starts in the folder the shell is in' {
    $name = 'ghosttycwdsplit' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $env:USERPROFILE $name
    New-Item -ItemType Directory $dir | Out-Null
    try {
        $p = Start-Ghostty $binds
        Send-Text $p "cd $name"
        Send-Key $p 0x0D 1500
        Send-Key $p $F2 2500                        # focus moves to the new pane
        Send-Text $p 'mkdir marker'
        Send-Key $p 0x0D 2500
        Assert (Test-Path (Join-Path $dir 'marker')) 'the new split did not start in the shell folder'
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'splits: right and down' {
    $p = Start-Ghostty $binds
    Send-Key $p $F2
    $kids = @(Get-Visible $p)
    Assert ($kids.Count -eq 2) "expected 2 panes, found $($kids.Count)"
    Assert ($kids[0].Y -eq $kids[1].Y -and $kids[0].X -ne $kids[1].X) 'panes should sit side by side'
    $gap = ($kids[1].X) - ($kids[0].X + $kids[0].W)
    Assert ($gap -gt 0 -and $gap -lt 12) "divider gap is $gap px"

    Send-Key $p $F3
    $kids = @(Get-Visible $p)
    Assert ($kids.Count -eq 3) "expected 3 panes, found $($kids.Count)"
    $right = @($kids | Where-Object { $_.X -gt 100 })
    Assert ($right.Count -eq 2 -and $right[0].X -eq $right[1].X -and $right[0].Y -ne $right[1].Y) 'the right side should be split top and bottom'
}

Test-Case 'splits: closing a pane collapses the split' {
    $p = Start-Ghostty $binds
    Send-Key $p $F2
    Send-Key $p $F5
    $kids = @(Get-Kids $p)
    Assert ($kids.Count -eq 1) "expected 1 terminal, found $($kids.Count)"
    $client = [GT]::Client($p.MainWindowHandle)
    Assert ($kids[0].W -eq $client[0]) 'the remaining terminal should fill the window'
}

Test-Case 'splits: zoom shows one pane and restores' {
    $p = Start-Ghostty $binds
    Send-Key $p $F2
    Send-Key $p $F7
    $zoomed = @(Get-Visible $p)
    Assert ($zoomed.Count -eq 1) "zoom left $($zoomed.Count) panes visible"
    Send-Key $p $F7
    Assert (@(Get-Visible $p).Count -eq 2) 'unzoom should show both panes again'
}

Test-Case 'tab bar: plus button adds a tab, close button removes it' {
    $p = Start-Ghostty $binds
    Send-Key $p $F1                       # two tabs, so the bar is visible
    $dpi = [GT]::GetDpiForWindow($p.MainWindowHandle)
    $scale = $dpi / 96.0
    $bar = [int][math]::Round(34 * $scale)
    $client = [GT]::Client($p.MainWindowHandle)
    $tabWidth = [math]::Min([int][math]::Round(220 * $scale), [int](($client[0] - $bar) / 2))

    # The plus button sits right after the tabs.
    Send-Mouse $p 0x201 (2 * $tabWidth + [int]($bar / 2)) ([int]($bar / 2))
    Send-Mouse $p 0x202 (2 * $tabWidth + [int]($bar / 2)) ([int]($bar / 2))
    Assert (@(Get-Kids $p).Count -eq 3) "plus button did not add a tab (terminals: $(@(Get-Kids $p).Count))"

    # Close the first tab with the x at the right edge of its tab.
    $tabWidth = [math]::Min([int][math]::Round(220 * $scale), [int](($client[0] - $bar) / 3))
    $closeX = $tabWidth - [int]($bar * 0.2) - [int]($bar * 0.3)
    Send-Mouse $p 0x201 $closeX ([int]($bar / 2))
    Send-Mouse $p 0x202 $closeX ([int]($bar / 2))
    Assert (@(Get-Kids $p).Count -eq 2) "close button did not remove a tab (terminals: $(@(Get-Kids $p).Count))"
}

Test-Case 'tab bar: clicking a tab switches to it' {
    $p = Start-Ghostty $binds
    Send-Key $p $F1
    $scale = [GT]::GetDpiForWindow($p.MainWindowHandle) / 96.0
    $bar = [int][math]::Round(34 * $scale)
    $before = @(Get-Kids $p | ForEach-Object { $_.Visible })
    # The new tab is active, so click the first tab, near its left edge.
    Send-Mouse $p 0x201 20 ([int]($bar / 2))
    Send-Mouse $p 0x202 20 ([int]($bar / 2))
    $after = @(Get-Kids $p | ForEach-Object { $_.Visible })
    Assert (($before -join ',') -ne ($after -join ',')) 'clicking the first tab did not change the visible terminal'
}

Test-Case 'tab bar: dragging a tab reorders it' {
    $p = Start-Ghostty $binds
    Send-Key $p $F1
    Send-Key $p $F1                       # tabs A, B, C in creation order
    $scale = [GT]::GetDpiForWindow($p.MainWindowHandle) / 96.0
    $bar = [int][math]::Round(34 * $scale)
    $client = [GT]::Client($p.MainWindowHandle)
    $tabWidth = [math]::Min([int][math]::Round(220 * $scale), [int](($client[0] - $bar) / 3))
    $y = [int]($bar / 2)

    # Drag the first tab (A) over the third slot. The order becomes B, C, A.
    Send-Mouse $p 0x201 20 $y 300
    Send-Mouse $p 0x200 (2 * $tabWidth + 20) $y 300
    Send-Mouse $p 0x202 (2 * $tabWidth + 20) $y 600

    # The first tab is now B, which is the second terminal that was created.
    Send-Key $p $F9
    $visible = @(Get-Kids $p | ForEach-Object { $_.Visible })
    Assert (@($visible | Where-Object { $_ }).Count -eq 1) 'expected exactly one visible terminal'
    Assert ($visible[1] -eq $true) "goto_tab:1 showed terminal $([array]::IndexOf($visible, $true)) instead of the second one, so the tab did not move"
}
Test-Case 'scrollbar: shows when the output scrolls and fades away' {
    # Short lines keep the right edge free of text, so only the scrollbar can
    # change the pixels there.
    $file = Join-Path $env:USERPROFILE 'ghosttyscroll'
    [IO.File]::WriteAllText($file, ((1..400 | ForEach-Object { "line $_" }) -join "`r`n"))
    try {
        $p = Start-Ghostty
        $client = [GT]::Client($p.MainWindowHandle)
        $background = @(0x28, 0x2C, 0x34)           # Ghostty's default background
        $edge = $client[0] - 5

        $before = Get-WindowImage $p
        $quiet = Count-ColumnDiffs $before $edge $client[1] $background
        Assert ($quiet -eq 0) "the right edge already differs from the background ($quiet pixels)"

        Send-Text $p 'type ghosttyscroll'
        Send-Key $p 0x0D 500
        $during = Count-ColumnDiffs (Get-WindowImage $p) $edge $client[1] $background
        Assert ($during -gt 3) "no scrollbar was drawn while scrolling (only $during pixels differ)"

        Start-Sleep -Milliseconds 3000
        $after = Count-ColumnDiffs (Get-WindowImage $p) $edge $client[1] $background
        Assert ($after -eq 0) "the scrollbar did not fade away ($after pixels still differ)"
    } finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'shell: progress reports and notifications are handled' {
    # cmd can send any escape sequence through its prompt ($E is the escape
    # character). This asks for 40 percent progress on the taskbar button and
    # shows a notification, on every prompt. There is nothing to read back
    # from Windows, so the check is that Ghostty takes them without trouble.
    $esc = '$E'
    $prompt = "$esc]9;4;1;40$esc\$esc]9;Ghostty test notification$esc\" + '$P$G'
    $p = Start-Ghostty @("--command=`"cmd.exe /k prompt $prompt`"")
    Send-Key $p 0x0D 1500
    $p.Refresh()
    Assert (-not $p.HasExited) 'Ghostty exited'
    Assert $p.Responding 'Ghostty stopped responding'
    Assert (@(Get-Kids $p).Count -eq 1) 'the window layout changed'
}
Test-Case 'clipboard: paste puts clipboard text into the shell' {
    $name = 'ghosttypaste' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $env:USERPROFILE $name
    Set-Clipboard -Value "mkdir $name"
    try {
        $p = Start-Ghostty @('--keybind=f4=paste_from_clipboard')
        Send-Key $p 0x73 1000                       # F4 pastes
        Send-Key $p 0x0D 2500
        Assert (Test-Path $dir) 'the pasted command did not run'
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'clipboard: copy puts the screen text on the clipboard' {
    Set-Clipboard -Value 'nothing copied yet'
    $p = Start-Ghostty @('--keybind=f11=select_all', '--keybind=f12=copy_to_clipboard')
    Send-Text $p 'echo copytestmarker'
    Send-Key $p 0x0D 1000
    Send-Key $p 0x7A 500                            # F11 selects everything
    Send-Key $p 0x7B 800                            # F12 copies it
    $copied = Get-Clipboard -Raw
    Assert ($copied -match 'copytestmarker') "the clipboard holds: $copied"
}

Test-Case 'clipboard: pasting several lines asks first' {
    $name = 'ghosttyunsafe' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $env:USERPROFILE $name
    # The line break at the end would run the command the moment it is pasted.
    Set-Clipboard -Value "mkdir $name`r`n"
    try {
        $p = Start-Ghostty @('--keybind=f4=paste_from_clipboard')
        Send-Key $p 0x73 1200
        $box = [GT]::FindWindowW('#32770', 'Ghostty')
        Assert ($box -ne [IntPtr]::Zero) 'no confirmation box appeared'
        Assert (-not (Test-Path $dir)) 'the paste ran before it was confirmed'
        [void][GT]::PostMessageW($box, 0x111, [IntPtr]6, [IntPtr]::Zero)    # Yes
        Start-Sleep -Milliseconds 2500
        Assert (Test-Path $dir) 'the paste did not run after Yes'
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        $box = [GT]::FindWindowW('#32770', 'Ghostty')
        if ($box -ne [IntPtr]::Zero) { [void][GT]::PostMessageW($box, 0x111, [IntPtr]2, [IntPtr]::Zero) }
    }
}

Test-Case 'clipboard: a program can write to the clipboard (kitty protocol)' {
    $script = Join-Path $env:TEMP 'ghostty-kitty-write.ps1'
    @'
$e = [char]27
function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
[Console]::Out.Write("$e]5522;type=write$e\")
[Console]::Out.Write("$e]5522;type=wdata:mime=$(B64 'text/plain');$(B64 'kittywrittentext')$e\")
[Console]::Out.Write("$e]5522;type=wdata$e\")
Start-Sleep 20
'@ | Set-Content $script -Encoding ASCII
    Set-Clipboard -Value 'nothing copied yet'
    try {
        $p = Start-Ghostty @("--command=`"powershell -NoProfile -ExecutionPolicy Bypass -File $script`"", '--clipboard-write=allow')
        Start-Sleep -Seconds 3
        $copied = (Get-Clipboard -Raw).Trim()
        Assert ($copied -eq 'kittywrittentext') "the clipboard holds: [$copied]"
    } finally {
        Remove-Item $script -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'clipboard: a program has to be allowed before it reads the clipboard' {
    # The answer to a read arrives as terminal input, which Windows' console
    # layer does not hand to programs for this kind of sequence, so the reply
    # cannot be read back here. What can be checked is that Ghostty asks first.
    $script = Join-Path $env:TEMP 'ghostty-kitty-read.ps1'
    @'
$e = [char]27
function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
[Console]::Out.Write("$e]5522;type=read;$(B64 'text/plain')$e\")
Start-Sleep 20
'@ | Set-Content $script -Encoding ASCII
    Set-Clipboard -Value 'kittyreadtext'
    try {
        $p = Start-Ghostty @("--command=`"powershell -NoProfile -ExecutionPolicy Bypass -File $script`"")
        $box = [IntPtr]::Zero
        for ($i = 0; $i -lt 40 -and $box -eq [IntPtr]::Zero; $i++) {
            Start-Sleep -Milliseconds 250
            $box = [GT]::FindWindowW('#32770', 'Ghostty')
        }
        Assert ($box -ne [IntPtr]::Zero) 'Ghostty did not ask before letting the program read the clipboard'
        [void][GT]::PostMessageW($box, 0x111, [IntPtr]7, [IntPtr]::Zero)    # No
        Start-Sleep -Milliseconds 800
        $p.Refresh()
        Assert (-not $p.HasExited -and $p.Responding) 'Ghostty did not carry on after the request was refused'
    } finally {
        Remove-Item $script -Force -ErrorAction SilentlyContinue
        $box = [GT]::FindWindowW('#32770', 'Ghostty')
        if ($box -ne [IntPtr]::Zero) { [void][GT]::PostMessageW($box, 0x111, [IntPtr]7, [IntPtr]::Zero) }
    }
}

Test-Case 'shell integration: PowerShell marks its prompts so Ghostty can jump to them' {
    $p = Start-Ghostty @('--command=powershell.exe', '--keybind=f4=jump_to_prompt:-1')
    Start-Sleep -Milliseconds 2500                     # PowerShell is slower to show its prompt
    # Two hundred lines push the prompt where the command was typed out of view.
    Send-Text $p '1..200'
    Send-Key $p 0x0D 2500
    $before = Get-WindowImage $p
    Send-Key $p 0x73 1200                              # F4 jumps to the previous prompt
    $after = Get-WindowImage $p
    $changed = 0
    for ($y = 40; $y -lt 560; $y += 3) {
        for ($x = 10; $x -lt 300; $x += 3) {
            $a = $before.Bitmap.GetPixel($before.OffsetX + $x, $before.OffsetY + $y)
            $b = $after.Bitmap.GetPixel($after.OffsetX + $x, $after.OffsetY + $y)
            if ($a.ToArgb() -ne $b.ToArgb()) { $changed++ }
        }
    }
    Assert ($changed -gt 150) "jumping to the previous prompt did not move the view ($changed samples changed), so the prompts are not marked"
}

Test-Case 'shell integration: cmd marks its prompts so Ghostty can jump to them' {
    $file = Join-Path $env:USERPROFILE 'ghosttyjump'
    [IO.File]::WriteAllText($file, ((1..300 | ForEach-Object { "jump line $_" }) -join "`r`n"))
    try {
        $p = Start-Ghostty @('--keybind=f4=jump_to_prompt:-1')
        Send-Text $p 'type ghosttyjump'
        Send-Key $p 0x0D 2500
        $before = Get-WindowImage $p
        Send-Key $p 0x73 1200
        $after = Get-WindowImage $p
        $changed = 0
        for ($y = 40; $y -lt 560; $y += 3) {
            for ($x = 10; $x -lt 300; $x += 3) {
                $a = $before.Bitmap.GetPixel($before.OffsetX + $x, $before.OffsetY + $y)
                $b = $after.Bitmap.GetPixel($after.OffsetX + $x, $after.OffsetY + $y)
                if ($a.ToArgb() -ne $b.ToArgb()) { $changed++ }
            }
        }
        Assert ($changed -gt 150) "jumping to the previous prompt did not move the view ($changed samples changed), so the prompts are not marked"
    } finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'command palette: opens, filters and runs a command' {
    $p = Start-Ghostty @('--keybind=f4=toggle_command_palette')
    Assert (@(Get-Kids $p).Count -eq 1) 'expected one terminal to start with'
    Assert ([GT]::FindByClass($p.MainWindowHandle, 'GhosttyPalette') -eq [IntPtr]::Zero) 'the palette was open already'

    Send-Key $p 0x73 800                                    # F4 opens the palette
    $palette = [GT]::FindByClass($p.MainWindowHandle, 'GhosttyPalette')
    Assert ($palette -ne [IntPtr]::Zero) 'the palette did not open'
    $edit = [GT]::FindByClass($palette, 'Edit')
    $list = [GT]::FindByClass($palette, 'ListBox')
    Assert ($edit -ne [IntPtr]::Zero -and $list -ne [IntPtr]::Zero) 'the palette has no search field or list'

    # Narrowing to one command leaves one row in the list.
    [void][GT]::SendMessageW($edit, 0x0C, [IntPtr]::Zero, 'New Tab')       # WM_SETTEXT
    Start-Sleep -Milliseconds 600
    $rows = [int][GT]::SendMessageW($list, 0x018B, [IntPtr]::Zero, $null)  # LB_GETCOUNT
    Assert ($rows -ge 1 -and $rows -le 3) "typing New Tab left $rows rows"

    [void][GT]::PostMessageW($edit, 0x100, [IntPtr]0x0D, [IntPtr]1)        # Enter
    Start-Sleep -Milliseconds 1800
    Assert ([GT]::FindByClass($p.MainWindowHandle, 'GhosttyPalette') -eq [IntPtr]::Zero) 'the palette stayed open after Enter'
    Assert (@(Get-Kids $p).Count -eq 2) "the New Tab command did not run (terminals: $(@(Get-Kids $p).Count))"
}

Test-Case 'command palette: Escape closes it' {
    $p = Start-Ghostty @('--keybind=f4=toggle_command_palette')
    Send-Key $p 0x73 800
    $palette = [GT]::FindByClass($p.MainWindowHandle, 'GhosttyPalette')
    Assert ($palette -ne [IntPtr]::Zero) 'the palette did not open'
    $edit = [GT]::FindByClass($palette, 'Edit')
    [void][GT]::PostMessageW($edit, 0x100, [IntPtr]0x1B, [IntPtr]1)        # Escape
    Start-Sleep -Milliseconds 800
    Assert ([GT]::FindByClass($p.MainWindowHandle, 'GhosttyPalette') -eq [IntPtr]::Zero) 'Escape did not close the palette'
}

Test-Case 'tab overview: shows pictures of the tabs and a click picks one' {
    $p = Start-Ghostty ($binds + '--keybind=f4=toggle_tab_overview')
    Send-Key $p $F1
    Send-Key $p $F1                                         # three tabs, the last one is active
    Assert (@(Get-Visible $p).Count -eq 1) 'expected one terminal showing before the overview'

    Send-Key $p 0x73 1000                                   # F4 opens the overview
    Assert (@(Get-Visible $p).Count -eq 0) 'the terminals should be hidden while the overview shows'

    # There is something drawn in the first picture, which sits in the top left.
    $image = Get-WindowImage $p
    $client = [GT]::Client($p.MainWindowHandle)
    $background = @(0x28, 0x2C, 0x34)
    $text = 0
    for ($y = [int]($client[1] * 0.05); $y -lt [int]($client[1] * 0.48); $y += 1) {
        for ($x = [int]($client[0] * 0.04); $x -lt [int]($client[0] * 0.48); $x += 1) {
            $c = $image.Bitmap.GetPixel($image.OffsetX + $x, $image.OffsetY + $y)
            if ([math]::Abs($c.R - $background[0]) + [math]::Abs($c.G - $background[1]) + [math]::Abs($c.B - $background[2]) -gt 90) { $text++ }
        }
    }
    Assert ($text -gt 40) "the first tab's picture looks empty ($text bright pixels)"

    # Click in the middle of the first of the four cells of the grid.
    Send-Mouse $p 0x201 ([int]($client[0] / 4)) ([int]($client[1] / 4)) 300
    Send-Mouse $p 0x202 ([int]($client[0] / 4)) ([int]($client[1] / 4)) 900
    $visible = @(Get-Kids $p | ForEach-Object { $_.Visible })
    Assert (@($visible | Where-Object { $_ }).Count -eq 1) 'exactly one terminal should show after choosing a tab'
    Assert ($visible[0] -eq $true) "the first tab was not chosen (terminal $([array]::IndexOf($visible, $true)) is showing)"
}

Test-Case 'tab overview: Escape returns to the tab you were on' {
    $p = Start-Ghostty ($binds + '--keybind=f4=toggle_tab_overview')
    Send-Key $p $F1                                         # two tabs, the second is active
    Send-Key $p 0x73 800
    Assert (@(Get-Visible $p).Count -eq 0) 'the overview did not open'
    [void][GT]::PostMessageW($p.MainWindowHandle, 0x100, [IntPtr]0x1B, [IntPtr]1)    # Escape
    Start-Sleep -Milliseconds 900
    $visible = @(Get-Kids $p | ForEach-Object { $_.Visible })
    Assert (@($visible | Where-Object { $_ }).Count -eq 1 -and $visible[1] -eq $true) 'Escape did not go back to the second tab'
}

Test-Case 'quick terminal: the shortcut shows a drop-down window and hides it again' {
    # The drop-down terminal goes on the screen the pointer is on. Put the pointer on the primary
    # screen, whose size is not changed by display scaling for this test process.
    Add-Type -AssemblyName System.Windows.Forms
    $savedPointer = [System.Windows.Forms.Cursor]::Position
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(([int]($([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width) / 2)), 300)
    try {
    $p = Start-Ghostty @('--keybind=f4=toggle_quick_terminal')
    $mainWindow = $p.MainWindowHandle
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyWindow')).Count -eq 1) 'expected one window to start with'

    Send-Key $p 0x73 2000                                   # F4 shows the drop-down terminal
    $windows = @([GT]::WindowsOf([uint32]$p.Id, 'GhosttyWindow'))
    Assert ($windows.Count -eq 2) "expected a second window, found $($windows.Count)"
    $quick = $windows | Where-Object { $_ -ne $mainWindow } | Select-Object -First 1
    Assert ([GT]::Visible($quick)) 'the drop-down window is not showing'

    # It has no frame and spans the top of the screen it is on.
    $style = [GT]::GetWindowLong($quick, -16)
    Assert (($style -band 0xC00000) -eq 0) 'the drop-down window has a title bar'
    $rect = [GT]::RectOf($quick)
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    Assert ($rect[1] -eq $screen.WorkingArea.Top) "its top is $($rect[1]), not the top of the screen at $($screen.WorkingArea.Top)"
    Assert (($rect[2] - $rect[0]) -eq $screen.WorkingArea.Width) "its width is $($rect[2] - $rect[0]), not the screen's $($screen.WorkingArea.Width)"
    Send-Key $p 0x73 1000                                   # pressed again, it hides
    Assert (-not [GT]::Visible($quick)) 'the drop-down window did not hide'
    Send-Key $p 0x73 1000
    Assert ([GT]::Visible($quick)) 'the drop-down window did not come back'
    } finally {
        [System.Windows.Forms.Cursor]::Position = $savedPointer
    }
}

Test-Case 'quick terminal: a global shortcut works from anywhere' {
    # Ctrl+Alt+F9 is pressed for real, with Ghostty not even having the keyboard.
    $p = Start-Ghostty @('--keybind=global:ctrl+alt+f9=toggle_quick_terminal')
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyWindow')).Count -eq 1) 'expected one window to start with'
    [GT]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [GT]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [GT]::keybd_event(0x78, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [GT]::keybd_event(0x78, 0, 2, [UIntPtr]::Zero)
    [GT]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [GT]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 2500
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyWindow')).Count -eq 2) 'the global shortcut did not open the drop-down terminal'
}

Test-Case 'quick terminal: closing the last normal window ends the program' {
    $p = Start-Ghostty @('--keybind=f4=toggle_quick_terminal', '--keybind=f10=close_tab:this')
    $mainWindow = $p.MainWindowHandle
    Send-Key $p 0x73 1500                                   # the drop-down terminal exists now
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyWindow')).Count -eq 2) 'the drop-down terminal did not open'
    # Close the ordinary window's only tab. The drop-down terminal alone should not keep Ghostty running.
    [void][GT]::PostMessageW($mainWindow, 0x100, [IntPtr]0x79, [IntPtr]1)
    Start-Sleep -Milliseconds 80
    [void][GT]::PostMessageW($mainWindow, 0x101, [IntPtr]0x79, [IntPtr]0xC0000001)
    Start-Sleep -Milliseconds 3500
    $p.Refresh()
    Assert $p.HasExited 'Ghostty is still running with only the drop-down terminal left'
}

Test-Case 'typing: a typed letter reaches the screen right away' {
    # Output from the shell must wake the renderer. Before this was fixed, the
    # letter only appeared when the cursor blink timer next fired, about half
    # a second later.
    $p = Start-Ghostty @('--cursor-style-blink=false')
    $window = $p.MainWindowHandle
    $rect = [GT]::RectOf($window)
    $bitmap = New-Object System.Drawing.Bitmap ($rect[2] - $rect[0]), ($rect[3] - $rect[1])
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $snapshot = {
        $dc = $graphics.GetHdc()
        [void][GT]::PrintWindow($window, $dc, 2)
        $graphics.ReleaseHdc($dc)
        $hash = 17
        for ($y = 40; $y -lt 140; $y += 2) {
            for ($x = 8; $x -lt 300; $x += 2) { $hash = ($hash * 31 + $bitmap.GetPixel($x, $y).ToArgb()) -band 0x7FFFFFFF }
        }
        $hash
    }
    Start-Sleep -Milliseconds 1500
    $before = & $snapshot
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Send-Key $p 0x41 0
    $changed = $false
    while ($stopwatch.ElapsedMilliseconds -lt 1500) {
        if ((& $snapshot) -ne $before) { $changed = $true; break }
    }
    $elapsed = $stopwatch.ElapsedMilliseconds
    Assert $changed 'the typed letter never appeared'
    Assert ($elapsed -lt 350) "the typed letter took $elapsed ms to appear"
}

Test-Case 'background opacity: the window is translucent only when asked' {
    $p = Start-Ghostty @()
    $style = [GT]::GetWindowLong($p.MainWindowHandle, -20)
    Assert (($style -band 0x80000) -eq 0) 'a default window should not be layered'
    $p.Kill(); $p.WaitForExit()

    $p = Start-Ghostty @('--background-opacity=0.5', '--background-blur=20')
    $style = [GT]::GetWindowLong($p.MainWindowHandle, -20)
    Assert (($style -band 0x80000) -ne 0) 'the window is not layered'
    $key = [uint32]0; $alpha = [byte]0; $flags = [uint32]0
    Assert ([GT]::GetLayeredWindowAttributes($p.MainWindowHandle, [ref]$key, [ref]$alpha, [ref]$flags)) 'could not read the layered attributes'
    Assert ([math]::Abs([int]$alpha - 128) -le 2) "expected alpha near 128, got $alpha"
    $p.Refresh()
    Assert (-not $p.HasExited -and $p.Responding) 'Ghostty stopped responding with a translucent window'
}

Test-Case 'inspector: opens in its own window, draws, and closes' {
    $p = Start-Ghostty @('--keybind=f4=inspector:toggle')
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyInspector')).Count -eq 0) 'the inspector was open already'

    Send-Key $p 0x73 2500                                   # F4 opens the inspector
    $windows = @([GT]::WindowsOf([uint32]$p.Id, 'GhosttyInspector'))
    Assert ($windows.Count -eq 1) "expected one inspector window, found $($windows.Count)"
    $inspector = $windows[0]
    Assert ([GT]::Visible($inspector)) 'the inspector window is not showing'
    $p.Refresh()
    Assert (-not $p.HasExited -and $p.Responding) 'Ghostty stopped responding after opening the inspector'

    # Something is drawn. The window is cleared to a flat dark color, and the
    # inspector's panels add many pixels of other colors.
    $rect = [GT]::RectOf($inspector)
    $bitmap = New-Object System.Drawing.Bitmap ($rect[2] - $rect[0]), ($rect[3] - $rect[1])
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    [void][GT]::PrintWindow($inspector, $dc, 2)
    $graphics.ReleaseHdc($dc)
    $colors = New-Object System.Collections.Generic.HashSet[int]
    for ($y = 40; $y -lt $bitmap.Height - 10; $y += 5) {
        for ($x = 10; $x -lt $bitmap.Width - 10; $x += 5) { [void]$colors.Add($bitmap.GetPixel($x, $y).ToArgb()) }
    }
    Assert ($colors.Count -gt 12) "the inspector window looks empty ($($colors.Count) colors)"

    [void][GT]::PostMessageW($inspector, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Start-Sleep -Milliseconds 1200
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyInspector')).Count -eq 0) 'the inspector window did not close'
    $p.Refresh()
    Assert (-not $p.HasExited) 'closing the inspector closed Ghostty'
}

Test-Case 'inspector: closing the terminal with the inspector open is safe' {
    $p = Start-Ghostty @('--keybind=f4=inspector:toggle', '--keybind=f10=close_tab:this')
    $main = $p.MainWindowHandle
    Send-Key $p 0x73 2000
    Assert (@([GT]::WindowsOf([uint32]$p.Id, 'GhosttyInspector')).Count -eq 1) 'the inspector did not open'
    [void][GT]::PostMessageW($main, 0x100, [IntPtr]0x79, [IntPtr]1)
    Start-Sleep -Milliseconds 80
    [void][GT]::PostMessageW($main, 0x101, [IntPtr]0x79, [IntPtr]0xC0000001)
    Start-Sleep -Milliseconds 3500
    $p.Refresh()
    Assert $p.HasExited 'Ghostty did not exit cleanly after its last tab closed with the inspector open'
    Assert ($p.ExitCode -eq 0) "Ghostty exited with code 0x$($p.ExitCode.ToString('x'))"
}

Test-Case 'mouse: dragging selects text that can be copied' {
    $p = Start-Ghostty @('--keybind=f12=copy_to_clipboard')
    Set-Clipboard -Value 'nothing copied yet'
    Send-Text $p 'echo dragselectmarker'
    Send-Key $p 0x0D 1000
    # The output is on the fifth text row. Cells are 10 by 21 pixels with 2
    # pixels of padding, so drag from inside the first letter to inside the
    # last one of the sixteen letters.
    $terminal = [GT]::FirstChild($p.MainWindowHandle)
    $y = 2 + 4 * 21 + 10
    [void][GT]::PostMessageW($terminal, 0x201, [IntPtr]1, [GT]::MakeLParam(2 + 3, $y))
    Start-Sleep -Milliseconds 300
    [void][GT]::PostMessageW($terminal, 0x200, [IntPtr]1, [GT]::MakeLParam(2 + 80, $y))
    Start-Sleep -Milliseconds 300
    [void][GT]::PostMessageW($terminal, 0x200, [IntPtr]1, [GT]::MakeLParam(2 + 158, $y))
    Start-Sleep -Milliseconds 300
    [void][GT]::PostMessageW($terminal, 0x202, [IntPtr]0, [GT]::MakeLParam(2 + 158, $y))
    Start-Sleep -Milliseconds 500
    Send-Key $p 0x7B 800                            # F12 copies the selection
    $copied = (Get-Clipboard -Raw).Trim()
    Assert ($copied -eq 'dragselectmarker') "the clipboard holds: [$copied]"
}
Test-Case 'mouse: the wheel scrolls through earlier output' {
    $file = Join-Path $env:USERPROFILE 'ghosttywheel'
    [IO.File]::WriteAllText($file, ((1..400 | ForEach-Object { "wheel line $_" }) -join "`r`n"))
    function Count-Changes($one, $two) {
        $changed = 0
        for ($y = 40; $y -lt 560; $y += 3) {
            for ($x = 10; $x -lt 200; $x += 3) {
                $a = $one.Bitmap.GetPixel($one.OffsetX + $x, $one.OffsetY + $y)
                $b = $two.Bitmap.GetPixel($two.OffsetX + $x, $two.OffsetY + $y)
                if ($a.ToArgb() -ne $b.ToArgb()) { $changed++ }
            }
        }
        return $changed
    }
    try {
        $p = Start-Ghostty
        Send-Text $p 'type ghosttywheel'
        Send-Key $p 0x0D 2500
        $before = Get-WindowImage $p
        Start-Sleep -Milliseconds 400
        $still = Get-WindowImage $p
        Assert ((Count-Changes $before $still) -lt 10) 'the screen changed on its own, so scrolling cannot be measured'

        $terminal = [GT]::FirstChild($p.MainWindowHandle)
        # One wheel notch up is 120 in the high word of the parameter.
        for ($i = 0; $i -lt 10; $i++) {
            [void][GT]::PostMessageW($terminal, 0x20A, [IntPtr](120 * 65536), [GT]::MakeLParam(100, 100))
            Start-Sleep -Milliseconds 80
        }
        Start-Sleep -Milliseconds 700
        $after = Get-WindowImage $p
        $changed = Count-Changes $before $after
        Assert ($changed -gt 40) "the screen barely changed after scrolling ($changed samples)"
    } finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'window: the title bar takes the terminal colors' {
    $p = Start-Ghostty
    $image = Get-WindowImage $p
    # A spot in the middle of the title bar, away from the icon and buttons.
    $c = $image.Bitmap.GetPixel(500, 12)
    $background = @(0x28, 0x2C, 0x34)
    $off = [math]::Abs($c.R - $background[0]) + [math]::Abs($c.G - $background[1]) + [math]::Abs($c.B - $background[2])
    Assert ($off -le 12) "the title bar is ($($c.R), $($c.G), $($c.B)), not the terminal background"
}

Test-Case 'config: window position' {
    $p = Start-Ghostty @('--window-position-x=140', '--window-position-y=90')
    $origin = [GT]::WindowOrigin($p.MainWindowHandle)
    Assert ($origin[0] -eq 140 -and $origin[1] -eq 90) "the window is at $($origin -join ',')"
}
Test-Case 'search: the search box finds text and closes' {
    $p = Start-Ghostty @('--keybind=f4=start_search')
    Send-Text $p 'echo findmetoken'
    Send-Key $p 0x0D 1200
    $before = Get-WindowImage $p
    Assert ([GT]::FindByClass($p.MainWindowHandle, 'Edit') -eq [IntPtr]::Zero) 'the search box was there before searching'

    Send-Key $p 0x73 800                                    # F4 starts a search
    $edit = [GT]::FindByClass($p.MainWindowHandle, 'Edit')
    Assert ($edit -ne [IntPtr]::Zero) 'the search box did not appear'

    [void][GT]::SendMessageW($edit, 0x0C, [IntPtr]::Zero, 'findmetoken')   # WM_SETTEXT
    Start-Sleep -Milliseconds 1200
    $after = Get-WindowImage $p
    # Matches are highlighted, which changes the pixels of the text area.
    $changed = 0
    for ($y = 40; $y -lt 200; $y += 2) {
        for ($x = 10; $x -lt 400; $x += 2) {
            $a = $before.Bitmap.GetPixel($before.OffsetX + $x, $before.OffsetY + $y)
            $b = $after.Bitmap.GetPixel($after.OffsetX + $x, $after.OffsetY + $y)
            if ($a.ToArgb() -ne $b.ToArgb()) { $changed++ }
        }
    }
    Assert ($changed -gt 100) "the matches were not highlighted ($changed pixels changed)"

    [void][GT]::PostMessageW($edit, 0x100, [IntPtr]0x1B, [IntPtr]1)        # Escape
    Start-Sleep -Milliseconds 800
    Assert ([GT]::FindByClass($p.MainWindowHandle, 'Edit') -eq [IntPtr]::Zero) 'Escape did not close the search box'
}
Test-Case 'dividers: dragging resizes the panes' {
    $p = Start-Ghostty $binds
    Send-Key $p $F2
    $kids = @(Get-Visible $p)
    $left = $kids | Sort-Object X | Select-Object -First 1
    $dividerX = $left.X + $left.W + 1
    $y = [int]($left.Y + $left.H / 2)
    Send-Mouse $p 0x201 $dividerX $y 300
    Send-Mouse $p 0x200 ($dividerX + 100) $y 300
    Send-Mouse $p 0x202 ($dividerX + 100) $y 600
    $after = @(Get-Visible $p) | Sort-Object X
    $grew = $after[0].W - $left.W
    Assert ($grew -gt 60 -and $grew -lt 140) "left pane changed by $grew px, expected about 100"
}

# ----------------------------------------------------------------------------

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host ("{0} passed, {1} failed" -f ($results.Count - $failed.Count), $failed.Count)
Stop-TestGhostty
exit $failed.Count
