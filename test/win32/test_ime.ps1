# IME / Unicode Input Test for Ghostty
# Tests that CJK characters can be input and rendered correctly.
#
# Usage from WSL:
#   powershell.exe -ExecutionPolicy Bypass -File test_ime.ps1 -ExePath <path> -OutputDir <dir>

param(
    [Parameter(Mandatory=$true)]
    [string]$ExePath,

    [string]$OutputDir = $env:TEMP
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Win32Ime {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    // SendInput for simulating keyboard input
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public const uint WM_CLOSE = 0x0010;
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // Send a Unicode string using SendInput (simulates keyboard Unicode input)
    public static void SendUnicodeString(string text) {
        var inputs = new INPUT[text.Length * 2]; // keydown + keyup per char
        for (int i = 0; i < text.Length; i++) {
            inputs[i * 2] = new INPUT {
                type = INPUT_KEYBOARD,
                u = new INPUTUNION {
                    ki = new KEYBDINPUT {
                        wVk = 0,
                        wScan = (ushort)text[i],
                        dwFlags = KEYEVENTF_UNICODE,
                        time = 0,
                        dwExtraInfo = IntPtr.Zero
                    }
                }
            };
            inputs[i * 2 + 1] = new INPUT {
                type = INPUT_KEYBOARD,
                u = new INPUTUNION {
                    ki = new KEYBDINPUT {
                        wVk = 0,
                        wScan = (ushort)text[i],
                        dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP,
                        time = 0,
                        dwExtraInfo = IntPtr.Zero
                    }
                }
            };
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

function Find-GhosttyWindow {
    param([int]$ProcessId = 0)
    $found = $null
    $callback = [Win32Ime+EnumWindowsProc]{
        param($hWnd, $lParam)
        if (-not [Win32Ime]::IsWindowVisible($hWnd)) { return $true }
        $sb = New-Object System.Text.StringBuilder 256
        $wpid = [uint32]0
        [Win32Ime]::GetWindowThreadProcessId($hWnd, [ref]$wpid) | Out-Null
        if ($ProcessId -eq 0 -or $wpid -eq $ProcessId) {
            $script:found = @{ Handle = $hWnd; Pid = $wpid }
            return $false
        }
        return $true
    }
    [Win32Ime]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $script:found
}

function Take-Screenshot {
    param([IntPtr]$hWnd, [string]$Name)
    $rect = New-Object Win32Ime+RECT
    [Win32Ime]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $gfx.GetHdc()
    [Win32Ime]::PrintWindow($hWnd, $hdc, 2) | Out-Null
    $gfx.ReleaseHdc($hdc)
    $gfx.Dispose()
    $path = Join-Path $OutputDir "${Name}_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $path
}

# --- Main test ---

Write-Output "=== IME / Unicode Input Test ==="

# Launch ghostty
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ExePath
$psi.UseShellExecute = $true
$proc = [System.Diagnostics.Process]::Start($psi)
Write-Output "PID=$($proc.Id)"

# Wait for window
Start-Sleep -Seconds 3
$win = Find-GhosttyWindow -ProcessId $proc.Id
if (-not $win) {
    Write-Output "FAIL: Window not found"
    exit 1
}
Write-Output "Window found"

# Bring to foreground
[Win32Ime]::SetForegroundWindow($win.Handle) | Out-Null
Start-Sleep -Milliseconds 500

# Test 1: Type an echo command with CJK characters using SendInput Unicode
# This simulates what happens when a user types CJK via IME - the characters
# arrive as WM_CHAR with Unicode codepoints.
Write-Output "Sending: echo followed by CJK characters..."
[System.Windows.Forms.SendKeys]::SendWait("echo ")
Start-Sleep -Milliseconds 200

# Send Chinese characters via PostMessage(WM_CHAR) directly to the HWND.
# This is equivalent to what an IME produces through the WM_IME_COMPOSITION
# path or what TranslateMessage generates from keyboard input.
# Characters: 你好世界 (Hello World in Chinese)
$WM_CHAR = 0x0102
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$VK_PACKET = 0xE7

$chars = @(0x4F60, 0x597D, 0x4E16, 0x754C)  # 你好世界
foreach ($c in $chars) {
    # Send VK_PACKET keydown (sets expect_char_from_packet flag)
    [Win32Ime]::PostMessage($win.Handle, $WM_KEYDOWN, [IntPtr]$VK_PACKET, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 20
    # Send WM_CHAR with the actual Unicode character
    [Win32Ime]::PostMessage($win.Handle, $WM_CHAR, [IntPtr]$c, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 20
    # Send VK_PACKET keyup
    [Win32Ime]::PostMessage($win.Handle, $WM_KEYUP, [IntPtr]$VK_PACKET, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 20
}
Write-Output "Sent 4 CJK characters via PostMessage"
Start-Sleep -Milliseconds 500

[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 1

# Take screenshot
$path = Take-Screenshot -hWnd $win.Handle -Name "ime_cjk"
Write-Output "SCREENSHOT=$path"

# Test 2: Send emoji via Unicode (supplementary plane, requires surrogate pairs)
Write-Output "Sending: echo followed by emoji..."
[System.Windows.Forms.SendKeys]::SendWait("echo ")
Start-Sleep -Milliseconds 200

# Send 🎉 (U+1F389) - this tests surrogate pair handling
# High surrogate: 0xD83C, Low surrogate: 0xDF89
$surrogates = @(0xD83C, 0xDF89)
foreach ($c in $surrogates) {
    [Win32Ime]::PostMessage($win.Handle, $WM_KEYDOWN, [IntPtr]$VK_PACKET, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 20
    [Win32Ime]::PostMessage($win.Handle, $WM_CHAR, [IntPtr]$c, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 20
    [Win32Ime]::PostMessage($win.Handle, $WM_KEYUP, [IntPtr]$VK_PACKET, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 20
}
Write-Output "Sent emoji surrogate pair via PostMessage"
Start-Sleep -Milliseconds 500

[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Seconds 1

# Take final screenshot
$path2 = Take-Screenshot -hWnd $win.Handle -Name "ime_emoji"
Write-Output "SCREENSHOT=$path2"

# Cleanup
[Win32Ime]::PostMessage($win.Handle, [Win32Ime]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Seconds 1
try { $proc.Kill() } catch {}

Write-Output "DONE"
