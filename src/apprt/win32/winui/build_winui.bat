@echo off
setlocal enabledelayedexpansion
REM Build script for ghostty_winui.dll (WinUI 3 shim DLL).
REM Usage: build_winui.bat <install_prefix>
REM   install_prefix: Zig build install path (e.g. zig-out)
REM
REM The DLL is placed in <install_prefix>\bin\ghostty_winui.dll

set "INSTALL_PREFIX=%~1"
if "%INSTALL_PREFIX%"=="" (
    echo Usage: build_winui.bat ^<install_prefix^>
    exit /b 1
)

REM Find vcvarsall.bat from Visual Studio (try common locations)
set "VCVARSALL="
for /d %%V in ("C:\Program Files\Microsoft Visual Studio\*") do (
    for /d %%E in ("%%V\*") do (
        if exist "%%E\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VCVARSALL=%%E\VC\Auxiliary\Build\vcvarsall.bat"
        )
    )
)
for /d %%V in ("C:\Program Files (x86)\Microsoft Visual Studio\*") do (
    for /d %%E in ("%%V\*") do (
        if exist "%%E\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VCVARSALL=%%E\VC\Auxiliary\Build\vcvarsall.bat"
        )
    )
)

if "%VCVARSALL%"=="" (
    echo ERROR: Could not find vcvarsall.bat. Install Visual Studio with C++ workload.
    exit /b 1
)

call "%VCVARSALL%" x64 >nul 2>&1
if errorlevel 1 (
    echo ERROR: vcvarsall.bat failed
    exit /b 1
)

REM Get the source directory (strip trailing backslash from %~dp0)
set "SRC_DIR=%~dp0"
if "%SRC_DIR:~-1%"=="\" set "SRC_DIR=%SRC_DIR:~0,-1%"

set "BUILD_DIR=%TEMP%\ghostty_winui_build"

echo [WinUI] Source: %SRC_DIR%
echo [WinUI] Build:  %BUILD_DIR%
echo [WinUI] Configuring CMake...
cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 (
    echo ERROR: CMake configure failed
    exit /b 1
)

echo [WinUI] Building ghostty_winui.dll...
cmake --build "%BUILD_DIR%"
if errorlevel 1 (
    echo ERROR: CMake build failed
    exit /b 1
)

echo [WinUI] Installing to %INSTALL_PREFIX%\bin\
if not exist "%INSTALL_PREFIX%\bin" mkdir "%INSTALL_PREFIX%\bin"
copy /Y "%BUILD_DIR%\bin\ghostty_winui.dll" "%INSTALL_PREFIX%\bin\ghostty_winui.dll" >nul
if errorlevel 1 (
    echo ERROR: Failed to copy ghostty_winui.dll
    exit /b 1
)
copy /Y "%BUILD_DIR%\compile_commands.json" "%SRC_DIR%\compile_commands.json" >nul

REM Copy the Windows App SDK Bootstrap DLL (required runtime dependency).
set "APPSDK_DIR="
for /d %%D in ("%USERPROFILE%\.nuget\packages\microsoft.windowsappsdk\*") do (
    set "APPSDK_DIR=%%D"
)
if defined APPSDK_DIR (
    set "BOOTSTRAP_DLL=%APPSDK_DIR%\runtimes\win-x64\native\Microsoft.WindowsAppRuntime.Bootstrap.dll"
    if exist "!BOOTSTRAP_DLL!" (
        copy /Y "!BOOTSTRAP_DLL!" "%INSTALL_PREFIX%\bin\Microsoft.WindowsAppRuntime.Bootstrap.dll" >nul
        echo [WinUI] Copied Microsoft.WindowsAppRuntime.Bootstrap.dll
    ) else (
        echo WARNING: Microsoft.WindowsAppRuntime.Bootstrap.dll not found in SDK package
    )
)

echo [WinUI] ghostty_winui.dll built successfully
