$ErrorActionPreference = "Stop"

$vsDevCmd = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
$gitCmd = "C:\Program Files\Git\cmd"
$gitUsrBin = "C:\Program Files\Git\usr\bin"
$systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
$userHome = if ($env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOMEDRIVE -and $env:HOMEPATH) {
    "$($env:HOMEDRIVE)$($env:HOMEPATH)"
} elseif ($env:USERNAME) {
    Join-Path $systemDrive "Users\$($env:USERNAME)"
} else {
    Join-Path $systemDrive "Users"
}
$programFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { Join-Path $systemDrive "Program Files" }
$appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $userHome "AppData\Roaming" }
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $userHome "AppData\Local" }
$tempDir = if ($env:TEMP) { $env:TEMP } else { Join-Path $localAppData "Temp" }
$tmpDir = if ($env:TMP) { $env:TMP } else { $tempDir }

if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig-0.15.2"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig-x86_64-windows-0.15.2"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $programFiles "Zig"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}

if (-not (Test-Path $vsDevCmd)) {
    throw "Missing VS Dev shell bootstrap: $vsDevCmd"
}
if (-not (Test-Path (Join-Path $gitCmd "git.exe"))) {
    throw "Missing Git executable under $gitCmd"
}
if (-not (Test-Path (Join-Path $gitUsrBin "sh.exe"))) {
    throw "Missing Git runtime under $gitUsrBin"
}
if (-not $env:ZIG_HOME) {
    throw "Zig 0.15.2+ not found. Set ZIG_HOME or install Zig under $userHome\tools\zig or $programFiles\Zig."
}
if (-not (Test-Path (Join-Path $env:ZIG_HOME "zig.exe"))) {
    throw "Missing zig.exe under $env:ZIG_HOME"
}
$env:APPDATA = $appData
$env:LOCALAPPDATA = $localAppData
$env:TEMP = $tempDir
$env:TMP = $tmpDir
$env:USERPROFILE = $userHome
$env:HOMEDRIVE = [System.IO.Path]::GetPathRoot($userHome).TrimEnd('\')
$env:HOMEPATH = $userHome.Substring($env:HOMEDRIVE.Length)
$env:SystemDrive = $systemDrive
New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:LOCALAPPDATA "zig"
$env:ZIG_LOCAL_CACHE_DIR = Join-Path (Get-Location) ".zig-cache"

$bootstrap = @"
call "$vsDevCmd" -arch=x64 || exit /b 1
set "PATH=$gitCmd;$gitUsrBin;$env:ZIG_HOME;%PATH%"
set "APPDATA=$env:APPDATA"
set "LOCALAPPDATA=$env:LOCALAPPDATA"
set "TEMP=$env:TEMP"
set "TMP=$env:TMP"
set "ZIG_GLOBAL_CACHE_DIR=$env:ZIG_GLOBAL_CACHE_DIR"
set "ZIG_LOCAL_CACHE_DIR=$env:ZIG_LOCAL_CACHE_DIR"
echo == Versions ==
where git || exit /b 1
where cl || exit /b 1
where link || exit /b 1
where rc || exit /b 1
where zig || exit /b 1
git --version || exit /b 1
zig version || exit /b 1
cl 2>&1 | findstr /c:"Version" || exit /b 1
echo == WSL ==
if "%DEV_WINDOWS_CHECK_WSL%"=="1" (
wsl.exe --status || exit /b 1
wsl.exe -l -v || exit /b 1
) else (
echo skipped ^(set DEV_WINDOWS_CHECK_WSL=1 to probe WSL^)
)
"@

cmd.exe /d /c $bootstrap
