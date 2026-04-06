@echo off
setlocal

set "_SYSTEM_DRIVE=%SystemDrive%"
if "%_SYSTEM_DRIVE%"=="" set "_SYSTEM_DRIVE=C:"
set "_USER_HOME=%USERPROFILE%"
if "%_USER_HOME%"=="" set "_USER_HOME=%HOMEDRIVE%%HOMEPATH%"
if "%_USER_HOME%"=="" set "_USER_HOME=%_SYSTEM_DRIVE%\Users\%USERNAME%"

set "ZIG_EXE=zig.exe"
if not "%ZIG_HOME%"=="" if exist "%ZIG_HOME%\zig.exe" set "ZIG_EXE=%ZIG_HOME%\zig.exe"
if "%ZIG_GLOBAL_CACHE_DIR%"=="" set "ZIG_GLOBAL_CACHE_DIR=%_USER_HOME%\AppData\Local\zig"
set "DOWNLOAD_DIR=%CD%\.zig-cache\downloads"

where bitsadmin >nul 2>nul || (
  echo Missing bitsadmin.exe
  exit /b 1
)

where "%ZIG_EXE%" >nul 2>nul
if errorlevel 1 if not exist "%ZIG_EXE%" (
  echo Missing zig executable. Run this via scripts\dev-windows.cmd or set ZIG_HOME.
  exit /b 1
)

if not exist "%ZIG_GLOBAL_CACHE_DIR%" mkdir "%ZIG_GLOBAL_CACHE_DIR%" >nul 2>nul
if not exist "%DOWNLOAD_DIR%" mkdir "%DOWNLOAD_DIR%" >nul 2>nul

call :seed "https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz" "libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/vaxis-7dbb9fd3122e4ffad262dd7c151d80d863b68558.tar.gz" "vaxis-7dbb9fd3122e4ffad262dd7c151d80d863b68558.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz" "z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/zig_objc-f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae.tar.gz" "zig_objc-f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/zig_js-04db83c617da1956ac5adc1cb9ba1e434c1cb6fd.tar.gz" "zig_js-04db83c617da1956ac5adc1cb9ba1e434c1cb6fd.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz" "uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/zig_wayland-1b5c038ec10da20ed3a15b0b2a6db1c21383e8ea.tar.gz" "zig_wayland-1b5c038ec10da20ed3a15b0b2a6db1c21383e8ea.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/zf-3c52637b7e937c5ae61fd679717da3e276765b23.tar.gz" "zf-3c52637b7e937c5ae61fd679717da3e276765b23.tar.gz" || exit /b 1
call :seed "https://github.com/ivanstepanovftw/zigimg/archive/d7b7ab0ba0899643831ef042bd73289510b39906.tar.gz" "zigimg-d7b7ab0ba0899643831ef042bd73289510b39906.tar.gz" || exit /b 1
call :seed "https://mirrors.lug.mtu.edu/gentoo/distfiles/59/uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM.tar.gz" "uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/gobject-2025-11-08-23-1.tar.zst" "gobject-2025-11-08-23-1.tar.zst" || exit /b 1
call :seed "https://deps.files.ghostty.org/wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz" "wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz" || exit /b 1
call :seedOptional "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.47/wayland-protocols-1.47.tar.gz" "wayland-protocols-1.47.tar.gz"
call :seed "https://deps.files.ghostty.org/plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz" "plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz" "JetBrainsMono-2.304.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz" "NerdFontsSymbolsOnly-3.4.0.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/ghostty-themes-release-20260323-152405-a2c7b60.tgz" "ghostty-themes-release-20260323-152405-a2c7b60.tgz" || exit /b 1
call :seed "https://deps.files.ghostty.org/breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz" "breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz" "DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz" || exit /b 1
call :seed "https://github.com/ocornut/imgui/archive/refs/tags/v1.92.5-docking.tar.gz" "imgui-v1.92.5-docking.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/fontconfig-2.14.2.tar.gz" "fontconfig-2.14.2.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz" "freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz" "glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/gtk4-layer-shell-1.1.0.tar.gz" "gtk4-layer-shell-1.1.0.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/wayland-protocols-258d8f88f2c8c25a830c6316f87d23ce1a0f12d9.tar.gz" "wayland-protocols-258d8f88f2c8c25a830c6316f87d23ce1a0f12d9.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/harfbuzz-11.0.0.tar.xz" "harfbuzz-11.0.0.tar.xz" || exit /b 1
call :seed "https://deps.files.ghostty.org/highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz" "highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/gettext-0.24.tar.gz" "gettext-0.24.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz" "libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/libxml2-2.11.5.tar.gz" "libxml2-2.11.5.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz" "oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz" "sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz" "spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/utfcpp-1220d4d18426ca72fc2b7e56ce47273149815501d0d2395c2a98c726b31ba931e641.tar.gz" "utfcpp-1220d4d18426ca72fc2b7e56ce47273149815501d0d2395c2a98c726b31ba931e641.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/wuffs-122037b39d577ec2db3fd7b2130e7b69ef6cc1807d68607a7c232c958315d381b5cd.tar.gz" "wuffs-122037b39d577ec2db3fd7b2130e7b69ef6cc1807d68607a7c232c958315d381b5cd.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz" "pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz" || exit /b 1
call :seed "https://deps.files.ghostty.org/zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz" "zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz" || exit /b 1

echo Seeded Zig cache under "%ZIG_GLOBAL_CACHE_DIR%"
exit /b 0

:seed
set "URL=%~1"
set "ARCHIVE=%DOWNLOAD_DIR%\%~2"
echo == %~2 ==
if not exist "%ARCHIVE%" (
  bitsadmin /transfer winghostty-%~n2 /download /priority foreground %URL% "%ARCHIVE%" || exit /b 1
)
"%ZIG_EXE%" fetch --global-cache-dir "%ZIG_GLOBAL_CACHE_DIR%" "%ARCHIVE%" || exit /b 1
exit /b 0

:seedOptional
set "URL=%~1"
set "ARCHIVE=%DOWNLOAD_DIR%\%~2"
echo == %~2 (optional) ==
if not exist "%ARCHIVE%" (
  bitsadmin /transfer winghostty-%~n2 /download /priority foreground %URL% "%ARCHIVE%" >nul 2>nul || (
    echo Skipping optional dependency archive: %~2
    exit /b 0
  )
)
"%ZIG_EXE%" fetch --global-cache-dir "%ZIG_GLOBAL_CACHE_DIR%" "%ARCHIVE%" >nul 2>nul || (
  echo Skipping optional dependency seed: %~2
  exit /b 0
)
exit /b 0
