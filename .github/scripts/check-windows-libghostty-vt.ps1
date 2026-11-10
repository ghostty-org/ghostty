<#
.SYNOPSIS
Checks that a libghostty-vt install tree works for a Windows C program.

.DESCRIPTION
Use this script to confirm that a libghostty-vt install tree for Windows is
complete and usable. The tree can be the output of `zig build --prefix` or an
unzipped release.

The script checks the tree in three steps:

1. It confirms that the libraries, headers, pkg-config files and CMake
   package files are present.
2. It writes a small C program that uses the CMake package, the same way a
   real project would:

       find_package(ghostty-vt CONFIG REQUIRED)
       target_link_libraries(consumer PRIVATE ghostty-vt::ghostty-vt)

   It then builds the program with CMake. On a machine with Visual Studio,
   CMake uses the Visual Studio compiler and linker.
3. It runs the program with the tree's bin directory on PATH, so Windows can
   find ghostty-vt.dll. The program calls one libghostty-vt function and
   exits with 0 if the call succeeds.

The only location the script gives CMake is -Prefix. A tree that still
depends on the directory it was built in fails, which makes the script
suitable for checking a tree after it has been moved or unzipped.

.PARAMETER Prefix
The root directory of the install tree, the one that contains bin, include
and lib.

.PARAMETER WorkDir
The directory where the script writes and builds the test program. The
directory must not exist yet. This keeps a build left over from an earlier
run from hiding a failure. By default the script creates a new directory
under the system temporary directory.

.EXAMPLE
./check-windows-libghostty-vt.ps1 -Prefix C:\ghostty-vt

Checks the install tree in C:\ghostty-vt, building the test program in a new
temporary directory.

.EXAMPLE
Expand-Archive ghostty-vt-1.0.0-x86_64-windows-gnu.zip -DestinationPath C:\unzipped
./check-windows-libghostty-vt.ps1 `
    -Prefix C:\unzipped\ghostty-vt-1.0.0-x86_64-windows-gnu `
    -WorkDir C:\consumer

Checks an unzipped release, building the test program in C:\consumer so the
build files can be inspected afterwards.

.NOTES
The script's exit code tells you which step failed:

    0          Every check passed.
    1          The tree or a required file is missing, -WorkDir already
               exists, or the build produced no program.
    Other      CMake failed and this is its exit code, or the test program
               failed and this is the program's exit code.

The script prints the test program's exit code in hexadecimal. When Windows
cannot load a program, the exit code is a Windows error code that is easier
to look up in that form. For example, 0xC0000135 means a required DLL was
not found.
#>
#Requires -Version 7

param(
    [Parameter(Mandatory)]
    [string] $Prefix,

    [PSDefaultValue(Help = 'A new directory under the system temporary directory')]
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "ghostty-vt-consumer-$([guid]::NewGuid().ToString('N'))")
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Prefix -PathType Container)) {
    Write-Error "install tree not found: $Prefix" -ErrorAction Continue
    exit 1
}
$Prefix = (Resolve-Path -LiteralPath $Prefix).Path

if (Test-Path -LiteralPath $WorkDir) {
    Write-Error "work directory already exists: $WorkDir" -ErrorAction Continue
    exit 1
}

# Paths are relative to the prefix. include/ghostty/vt is a directory and
# the rest are files.
$expected = @(
    "bin/ghostty-vt.dll"
    "lib/ghostty-vt.lib"
    "lib/ghostty-vt-static.lib"
    "include/ghostty/vt.h"
    "include/ghostty/vt"
    "lib/pkgconfig/libghostty-vt.pc"
    "lib/pkgconfig/libghostty-vt-static.pc"
    "lib/cmake/ghostty-vt/ghostty-vt-config.cmake"
    "lib/cmake/ghostty-vt/ghostty-vt-config-version.cmake"
)
$missing = $expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Prefix $_)) }
if ($missing) {
    Write-Error "missing from the install tree: $($missing -join ', ')" -ErrorAction Continue
    exit 1
}

New-Item -ItemType Directory $WorkDir | Out-Null
$build = Join-Path $WorkDir "build"

@'
cmake_minimum_required(VERSION 3.19)
project(consumer C)
find_package(ghostty-vt CONFIG REQUIRED)
add_executable(consumer main.c)
target_link_libraries(consumer PRIVATE ghostty-vt::ghostty-vt)
'@ | Set-Content (Join-Path $WorkDir "CMakeLists.txt")

@'
#include <ghostty/vt.h>
int main(void) {
    bool simd = false;
    return ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD, &simd) == GHOSTTY_SUCCESS ? 0 : 1;
}
'@ | Set-Content (Join-Path $WorkDir "main.c")

# CMake learns where the tree is from CMAKE_PREFIX_PATH and nothing else.
# If the package files still point at the directory the tree was built in,
# this step or the link fails.
cmake -S $WorkDir -B $build "-DCMAKE_PREFIX_PATH=$Prefix"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Visual Studio builds put the program in a Release subdirectory. Ninja and
# Makefile builds put it directly in the build directory.
$exe = @(
    (Join-Path $build "Release/consumer.exe")
    (Join-Path $build "consumer.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $exe) {
    Write-Error "consumer.exe not found under $build" -ErrorAction Continue
    exit 1
}

# Windows searches a fixed list of places for a program's DLLs. The list
# includes PATH but not the directory the program was linked against, so the
# tree's bin directory has to be on PATH for ghostty-vt.dll to load.
$env:PATH = "$(Join-Path $Prefix 'bin');$env:PATH"
& $exe
$code = $LASTEXITCODE
"exit code: 0x{0:X8}" -f $code
exit $code
