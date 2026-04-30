cmake_minimum_required(VERSION 3.19)

# --- Determine cross-compilation target before project() --------------------
#
# We need to know the target before project() so we can set up zig cc as the
# C/C++ compiler for the cross target.

# Pick a cross-compilation target: build for a different OS than the host.
# Can be overridden with -DZIG_TARGET=... on the command line.
if(NOT ZIG_TARGET)
    # CMAKE_HOST_SYSTEM_PROCESSOR may not be set before project(), so
    # fall back to `uname -m`.
    if(CMAKE_HOST_SYSTEM_PROCESSOR)
        set(_arch "${CMAKE_HOST_SYSTEM_PROCESSOR}")
    else()
        execute_process(COMMAND uname -m OUTPUT_VARIABLE _arch OUTPUT_STRIP_TRAILING_WHITESPACE)
    endif()
    if(_arch MATCHES "^(x86_64|AMD64)$")
        set(_arch "x86_64")
    elseif(_arch MATCHES "^(aarch64|arm64|ARM64)$")
        set(_arch "aarch64")
    endif()

    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
        set(ZIG_TARGET "${_arch}-windows-gnu")
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(ZIG_TARGET "${_arch}-linux-gnu")
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        set(ZIG_TARGET "${_arch}-linux-gnu")
    else()
        message(FATAL_ERROR
            "Cannot derive ZIG_TARGET for ${CMAKE_HOST_SYSTEM_NAME}. "
            "Pass -DZIG_TARGET=... manually.")
    endif()

    message(STATUS "Cross-compiling for ZIG_TARGET: ${ZIG_TARGET}")
endif()

# --- Set up zig cc as the cross compiler ------------------------------------

# GhosttyZigCompiler.cmake must be called before project().
# Downstream projects would copy this file into their tree; here we
# include it directly from the repo.
include(../../dist/cmake/GhosttyZigCompiler.cmake)
ghostty_zig_compiler(ZIG_TARGET "${ZIG_TARGET}")

project(c-vt-cmake-cross LANGUAGES C CXX)

include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG main
)
FetchContent_MakeAvailable(ghostty)

ghostty_vt_add_target(NAME cross ZIG_TARGET "${ZIG_TARGET}")

add_executable(c_vt_cmake_cross src/main.c)
target_link_libraries(c_vt_cmake_cross PRIVATE ghostty-vt-static-cross)
