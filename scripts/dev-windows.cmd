@echo off
setlocal

set "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
set "GIT_CMD=C:\Program Files\Git\cmd"
set "GIT_USR_BIN=C:\Program Files\Git\usr\bin"
set "_SYSTEM_DRIVE=%SystemDrive%"
if "%_SYSTEM_DRIVE%"=="" set "_SYSTEM_DRIVE=C:"
set "_USER_HOME=%USERPROFILE%"
if "%_USER_HOME%"=="" set "_USER_HOME=%HOMEDRIVE%%HOMEPATH%"
if "%_USER_HOME%"=="" set "_USER_HOME=%_SYSTEM_DRIVE%\Users\%USERNAME%"
set "_PROGRAM_FILES=%ProgramFiles%"
if "%_PROGRAM_FILES%"=="" set "_PROGRAM_FILES=%_SYSTEM_DRIVE%\Program Files"
set "_APPDATA=%APPDATA%"
if "%_APPDATA%"=="" set "_APPDATA=%_USER_HOME%\AppData\Roaming"
set "_LOCALAPPDATA=%LOCALAPPDATA%"
if "%_LOCALAPPDATA%"=="" set "_LOCALAPPDATA=%_USER_HOME%\AppData\Local"
set "_TEMP_DIR=%TEMP%"
if "%_TEMP_DIR%"=="" set "_TEMP_DIR=%_LOCALAPPDATA%\Temp"
set "_TMP_DIR=%TMP%"
if "%_TMP_DIR%"=="" set "_TMP_DIR=%_TEMP_DIR%"

if "%ZIG_HOME%"=="" if exist "%_USER_HOME%\tools\zig-0.15.2\zig.exe" set "ZIG_HOME=%_USER_HOME%\tools\zig-0.15.2"
if "%ZIG_HOME%"=="" if exist "%_USER_HOME%\tools\zig-x86_64-windows-0.15.2\zig.exe" set "ZIG_HOME=%_USER_HOME%\tools\zig-x86_64-windows-0.15.2"
if "%ZIG_HOME%"=="" if exist "%_USER_HOME%\tools\zig\zig.exe" set "ZIG_HOME=%_USER_HOME%\tools\zig"
if "%ZIG_HOME%"=="" if exist "%_PROGRAM_FILES%\Zig" set "ZIG_HOME=%_PROGRAM_FILES%\Zig"

if not exist "%VSDEVCMD%" (
  echo Missing VS Dev shell bootstrap: "%VSDEVCMD%"
  exit /b 1
)

if not exist "%GIT_CMD%\git.exe" (
  echo Missing Git: "%GIT_CMD%\git.exe"
  exit /b 1
)

if not exist "%GIT_USR_BIN%\sh.exe" (
  echo Missing Git runtime: "%GIT_USR_BIN%\sh.exe"
  exit /b 1
)

if "%ZIG_HOME%"=="" (
  echo Zig 0.15.2+ not found. Set ZIG_HOME or install Zig to "%_USER_HOME%\tools\zig" or "%_PROGRAM_FILES%\Zig".
  exit /b 1
)

if not exist "%ZIG_HOME%\zig.exe" (
  echo Zig executable not found at "%ZIG_HOME%\zig.exe"
  exit /b 1
)

call "%VSDEVCMD%" -arch=x64 || exit /b 1
for %%I in ("%_USER_HOME%") do (
  set "USERPROFILE=%%~fI"
  set "HOMEDRIVE=%%~dI"
  set "HOMEPATH=%%~pI"
)
set "SystemDrive=%_SYSTEM_DRIVE%"
set "APPDATA=%_APPDATA%"
set "LOCALAPPDATA=%_LOCALAPPDATA%"
set "TEMP=%_TEMP_DIR%"
set "TMP=%_TMP_DIR%"
if not exist "%LOCALAPPDATA%" mkdir "%LOCALAPPDATA%" >nul 2>nul
if not exist "%APPDATA%" mkdir "%APPDATA%" >nul 2>nul
if not exist "%TEMP%" mkdir "%TEMP%" >nul 2>nul
set "ZIG_GLOBAL_CACHE_DIR=%LOCALAPPDATA%\zig"
set "ZIG_LOCAL_CACHE_DIR=%CD%\.zig-cache"
set "PATH=%GIT_CMD%;%GIT_USR_BIN%;%ZIG_HOME%;%PATH%"

echo == Versions ==
where git || exit /b 1
where cl || exit /b 1
where link || exit /b 1
where rc || exit /b 1
where zig || exit /b 1
git --version || exit /b 1
zig version || exit /b 1
cl 2>&1 | findstr /c:"Version" || exit /b 1
for /f %%v in ('zig version') do set "ZIG_VERSION=%%v"
echo %ZIG_VERSION% | findstr /b /c:"0.15." >nul || (
  echo winghostty currently requires Zig 0.15.x. Resolved: %ZIG_VERSION%
  exit /b 1
)

echo == WSL ==
if "%DEV_WINDOWS_CHECK_WSL%"=="1" (
  wsl.exe --status || exit /b 1
  wsl.exe -l -v || exit /b 1
) else (
  echo skipped ^(set DEV_WINDOWS_CHECK_WSL=1 to probe WSL^)
)

if "%~1"=="" (
  cmd /k
  exit /b 0
)

%*
