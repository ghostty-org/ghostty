# GhosttyZigCompiler.cmake — set up zig cc as a cross compiler
#
# Provides ghostty_zig_compiler() which configures zig cc / zig c++ as
# the C/CXX compiler for a given Zig target triple. It creates small
# wrapper scripts (shell on Unix, .cmd on Windows) and sets the
# following CMake variables in the caller's scope:
#
#   CMAKE_C_COMPILER, CMAKE_CXX_COMPILER,
#   CMAKE_C_COMPILER_FORCED, CMAKE_CXX_COMPILER_FORCED,
#   CMAKE_SYSTEM_NAME, CMAKE_EXECUTABLE_SUFFIX (Windows only)
#
# This file is self-contained with no dependencies on the ghostty
# source tree. Copy it into your project and include it directly.
# It cannot be consumed via FetchContent because it must run before
# project(), but FetchContent_MakeAvailable triggers project()
# internally.
#
# Must be called BEFORE project() — CMake reads the compiler variables
# at project() time and won't re-detect after that.
#
# Usage:
#
#   cmake_minimum_required(VERSION 3.19)
#
#   include(cmake/GhosttyZigCompiler.cmake)
#   ghostty_zig_compiler(ZIG_TARGET x86_64-linux-gnu)
#
#   project(myapp LANGUAGES C CXX)
#
#   FetchContent_MakeAvailable(ghostty)
#   ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu)
#   target_link_libraries(myapp PRIVATE ghostty-vt-static-linux-amd64)
#
# See example/c-vt-cmake-cross/ for a complete working example.

include_guard(GLOBAL)

function(ghostty_zig_compiler)
    cmake_parse_arguments(PARSE_ARGV 0 _GZC "" "ZIG_TARGET" "")

    if(NOT _GZC_ZIG_TARGET)
        message(FATAL_ERROR "ghostty_zig_compiler: ZIG_TARGET is required")
    endif()

    find_program(_GZC_ZIG zig REQUIRED)

    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(_cc "${CMAKE_CURRENT_BINARY_DIR}/zig-cc.cmd")
        set(_cxx "${CMAKE_CURRENT_BINARY_DIR}/zig-cxx.cmd")
        file(WRITE "${_cc}" "@\"${_GZC_ZIG}\" cc -target ${_GZC_ZIG_TARGET} %*\n")
        file(WRITE "${_cxx}" "@\"${_GZC_ZIG}\" c++ -target ${_GZC_ZIG_TARGET} %*\n")
    else()
        set(_cc "${CMAKE_CURRENT_BINARY_DIR}/zig-cc")
        set(_cxx "${CMAKE_CURRENT_BINARY_DIR}/zig-c++")
        file(WRITE "${_cc}" "#!/bin/sh\nexec \"${_GZC_ZIG}\" cc -target ${_GZC_ZIG_TARGET} \"$@\"\n")
        file(WRITE "${_cxx}" "#!/bin/sh\nexec \"${_GZC_ZIG}\" c++ -target ${_GZC_ZIG_TARGET} \"$@\"\n")
        file(CHMOD "${_cc}" "${_cxx}"
            PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
    endif()

    set(CMAKE_C_COMPILER "${_cc}" PARENT_SCOPE)
    set(CMAKE_CXX_COMPILER "${_cxx}" PARENT_SCOPE)
    set(CMAKE_C_COMPILER_FORCED TRUE PARENT_SCOPE)
    set(CMAKE_CXX_COMPILER_FORCED TRUE PARENT_SCOPE)

    if(_GZC_ZIG_TARGET MATCHES "windows")
        set(CMAKE_SYSTEM_NAME Windows PARENT_SCOPE)
        set(CMAKE_EXECUTABLE_SUFFIX ".exe" PARENT_SCOPE)
    elseif(_GZC_ZIG_TARGET MATCHES "linux")
        set(CMAKE_SYSTEM_NAME Linux PARENT_SCOPE)
    elseif(_GZC_ZIG_TARGET MATCHES "darwin|macos")
        set(CMAKE_SYSTEM_NAME Darwin PARENT_SCOPE)
    endif()
endfunction()
