# CMake wrapper for libghostty-vt
#
# This file delegates to `zig build -Demit-lib-vt` to produce the shared library,
# headers, and pkg-config file. It exists so that CMake-based projects can
# consume libghostty-vt without interacting with the Zig build system
# directly. However, downstream users do still require `zig` on the PATH.
# Please consult the Ghostty docs for the required Zig version:
#
# https://ghostty.org/docs/install/build
#
# Building within the Ghostty repo
# ---------------------------------
#
#   cmake -B build
#   cmake --build build
#   cmake --install build --prefix /usr/local
#
# Pass extra flags to the Zig build with GHOSTTY_ZIG_BUILD_FLAGS:
#
#   cmake -B build -DGHOSTTY_ZIG_BUILD_FLAGS="-Demit-macos-app=false"
#
# Integrating into a downstream CMake project
# ---------------------------------------------
#
# Option 1 — FetchContent (recommended, no manual install step):
#
#   include(FetchContent)
#   FetchContent_Declare(ghostty
#       GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
#       GIT_TAG main
#   )
#   FetchContent_MakeAvailable(ghostty)
#
#   target_link_libraries(myapp PRIVATE ghostty-vt)        # shared
#   target_link_libraries(myapp PRIVATE ghostty-vt-static) # static
#
# To use a local checkout instead of fetching:
#
#   cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=/path/to/ghostty
#
# Option 2 — find_package (after installing to a prefix):
#
#   find_package(ghostty-vt REQUIRED)
#   target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt)        # shared
#   target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt-static) # static
#
# Cross-compilation
# -------------------
#
# For building libghostty-vt for a non-native Zig target (e.g. cross-
# compiling), use the ghostty_vt_add_target() function after FetchContent:
#
#   FetchContent_MakeAvailable(ghostty)
#   ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu)
#
#   target_link_libraries(myapp PRIVATE ghostty-vt-static-linux-amd64) # static
#   target_link_libraries(myapp PRIVATE ghostty-vt-linux-amd64)        # shared
#
# This handles zig discovery, build-type-to-optimize mapping, and output
# path conventions internally. Extra flags can be forwarded with ZIG_FLAGS:
#
#   ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu
#                         ZIG_FLAGS -Dsimd=false)
#
# See dist/cmake/README.md for more details, example/c-vt-cmake/ for a
# complete working example, and example/c-vt-cmake-cross/ for a cross-
# compilation example.

cmake_minimum_required(VERSION 3.19)
project(ghostty-vt VERSION 0.1.0 LANGUAGES C)

# --- Options ----------------------------------------------------------------

set(GHOSTTY_ZIG_BUILD_FLAGS "" CACHE STRING "Additional flags to pass to zig build")

# Map CMake build types to Zig optimization levels. The result is stored in
# _GHOSTTY_ZIG_OPT_FLAG so both the native build and ghostty_vt_add_target()
# can reuse it without duplicating the mapping logic.
set(_GHOSTTY_ZIG_OPT_FLAG "")
if(CMAKE_BUILD_TYPE)
    string(TOUPPER "${CMAKE_BUILD_TYPE}" _bt)
    if(_bt STREQUAL "RELEASE" OR _bt STREQUAL "MINSIZEREL" OR _bt STREQUAL "RELWITHDEBINFO")
        set(_GHOSTTY_ZIG_OPT_FLAG "-Doptimize=ReleaseFast")
    endif()
    unset(_bt)
endif()

if(_GHOSTTY_ZIG_OPT_FLAG)
    list(APPEND GHOSTTY_ZIG_BUILD_FLAGS "${_GHOSTTY_ZIG_OPT_FLAG}")
endif()

# --- Find Zig ----------------------------------------------------------------

find_program(ZIG_EXECUTABLE zig REQUIRED)
message(STATUS "Found zig: ${ZIG_EXECUTABLE}")

# --- Build via zig build -----------------------------------------------------

# The zig build installs into zig-out/ relative to the source tree.
set(ZIG_OUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/zig-out")

# Shared library names (zig build produces both shared and static).
if(APPLE)
    set(GHOSTTY_VT_LIBNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(GHOSTTY_VT_SONAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt.0${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(GHOSTTY_VT_REALNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt.0.1.0${CMAKE_SHARED_LIBRARY_SUFFIX}")
elseif(WIN32)
    set(GHOSTTY_VT_LIBNAME "ghostty-vt.dll")
    set(GHOSTTY_VT_REALNAME "ghostty-vt.dll")
    set(GHOSTTY_VT_IMPLIB "ghostty-vt.lib")
else()
    set(GHOSTTY_VT_LIBNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(GHOSTTY_VT_SONAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}.0")
    set(GHOSTTY_VT_REALNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}.0.1.0")
endif()

if(WIN32)
    set(GHOSTTY_VT_SHARED_LIBRARY "${ZIG_OUT_DIR}/bin/${GHOSTTY_VT_REALNAME}")
else()
    set(GHOSTTY_VT_SHARED_LIBRARY "${ZIG_OUT_DIR}/lib/${GHOSTTY_VT_REALNAME}")
endif()

# Static library name.
# On Windows, the static lib is named "ghostty-vt-static.lib" to avoid
# colliding with the DLL import library "ghostty-vt.lib".
if(WIN32)
    set(GHOSTTY_VT_STATIC_REALNAME "ghostty-vt-static.lib")
else()
    set(GHOSTTY_VT_STATIC_REALNAME "libghostty-vt.a")
endif()
set(GHOSTTY_VT_STATIC_LIBRARY "${ZIG_OUT_DIR}/lib/${GHOSTTY_VT_STATIC_REALNAME}")

# Ensure the output directories exist so CMake doesn't reject the
# INTERFACE_INCLUDE_DIRECTORIES before the zig build has run.
file(MAKE_DIRECTORY "${ZIG_OUT_DIR}/include")

# Custom command: run zig build -Demit-lib-vt (produces both shared and static)
add_custom_command(
    OUTPUT "${GHOSTTY_VT_SHARED_LIBRARY}" "${GHOSTTY_VT_STATIC_LIBRARY}" "${ZIG_OUT_DIR}/lib/${GHOSTTY_VT_IMPLIB}"
    COMMAND "${ZIG_EXECUTABLE}" build -Demit-lib-vt ${GHOSTTY_ZIG_BUILD_FLAGS}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building libghostty-vt via zig build..."
    USES_TERMINAL
)

add_custom_target(zig_build_lib_vt ALL
    DEPENDS "${GHOSTTY_VT_SHARED_LIBRARY}" "${GHOSTTY_VT_STATIC_LIBRARY}"
)

# Tell CMake's clean target to also remove Zig's output directory.
set_property(DIRECTORY APPEND PROPERTY
    ADDITIONAL_CLEAN_FILES "${ZIG_OUT_DIR}"
)

# --- IMPORTED library targets ------------------------------------------------

# Shared
add_library(ghostty-vt SHARED IMPORTED GLOBAL)
set_target_properties(ghostty-vt PROPERTIES
    IMPORTED_LOCATION "${GHOSTTY_VT_SHARED_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${ZIG_OUT_DIR}/include"
)
if(APPLE)
    set_target_properties(ghostty-vt PROPERTIES
        IMPORTED_SONAME "@rpath/${GHOSTTY_VT_SONAME}"
    )
elseif(WIN32)
    set_target_properties(ghostty-vt PROPERTIES
        IMPORTED_IMPLIB "${ZIG_OUT_DIR}/lib/${GHOSTTY_VT_IMPLIB}"
    )
else()
    set_target_properties(ghostty-vt PROPERTIES
        IMPORTED_SONAME "${GHOSTTY_VT_SONAME}"
    )
endif()
add_dependencies(ghostty-vt zig_build_lib_vt)

# Static
#
# On Linux and macOS, the static library is a fat archive that bundles
# the vendored SIMD dependencies (highway, simdutf). Consumers
# only need to link libc.
#
# On Windows, the SIMD dependencies are not bundled and must be linked
# separately.
#
# Building with -Dsimd=false removes all runtime dependencies.
add_library(ghostty-vt-static STATIC IMPORTED GLOBAL)
set_target_properties(ghostty-vt-static PROPERTIES
    IMPORTED_LOCATION "${GHOSTTY_VT_STATIC_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${ZIG_OUT_DIR}/include"
    INTERFACE_COMPILE_DEFINITIONS "GHOSTTY_STATIC"
)
if(WIN32)
    # On Windows, the Zig standard library uses NT API functions
    # (NtClose, NtCreateSection, etc.) and kernel32 functions that
    # consumers must link when using the static library.
    set_target_properties(ghostty-vt-static PROPERTIES
        INTERFACE_LINK_LIBRARIES "ntdll;kernel32"
    )
endif()
add_dependencies(ghostty-vt-static zig_build_lib_vt)

# --- Install ------------------------------------------------------------------

include(GNUInstallDirs)

# Install shared library
if(WIN32)
    # On Windows, install the DLL and PDB to bin/ and the import library to lib/
    install(FILES "${GHOSTTY_VT_SHARED_LIBRARY}" "${ZIG_OUT_DIR}/bin/ghostty-vt.pdb" TYPE BIN)
    install(FILES "${ZIG_OUT_DIR}/lib/${GHOSTTY_VT_IMPLIB}" TYPE LIB)
else()
    install(FILES "${GHOSTTY_VT_SHARED_LIBRARY}" TYPE LIB)
    # Install symlinks
    install(CODE "
        execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
            \"${GHOSTTY_VT_REALNAME}\"
            \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/${GHOSTTY_VT_SONAME}\")
        execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
            \"${GHOSTTY_VT_SONAME}\"
            \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/${GHOSTTY_VT_LIBNAME}\")
    ")
endif()

# Install static library
install(FILES "${GHOSTTY_VT_STATIC_LIBRARY}" TYPE LIB)

# Install headers
install(DIRECTORY "${ZIG_OUT_DIR}/include/ghostty" DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")

# --- CMake package config for find_package() ----------------------------------

include(CMakePackageConfigHelpers)

# Generate the config file
configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/dist/cmake/ghostty-vt-config.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/ghostty-vt-config.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/ghostty-vt"
)

# Generate the version file
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/ghostty-vt-config-version.cmake"
    VERSION "${PROJECT_VERSION}"
    COMPATIBILITY SameMajorVersion
)

# Install the config files
install(
    FILES
        "${CMAKE_CURRENT_BINARY_DIR}/ghostty-vt-config.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/ghostty-vt-config-version.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/ghostty-vt"
)

# --- Cross-compilation helper ------------------------------------------------
#
# For downstream projects that need to build libghostty-vt for a specific
# Zig target triple. For native builds, use the IMPORTED targets above
# (ghostty-vt, ghostty-vt-static) directly.
#
# Usage (in a downstream CMakeLists.txt after FetchContent_MakeAvailable):
#
#   ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu)
#
# Creates:
#   ghostty-vt-static-linux-amd64   (IMPORTED STATIC library)
#   ghostty-vt-linux-amd64          (IMPORTED SHARED library)
#
# Optional ZIG_FLAGS to pass additional flags to zig build:
#
#   ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu
#                         ZIG_FLAGS -Dsimd=false)

function(ghostty_vt_add_target)
    cmake_parse_arguments(PARSE_ARGV 0 _GVT "" "NAME;ZIG_TARGET" "ZIG_FLAGS")

    if(NOT _GVT_NAME)
        message(FATAL_ERROR "ghostty_vt_add_target: NAME is required")
    endif()
    if(NOT _GVT_ZIG_TARGET)
        message(FATAL_ERROR "ghostty_vt_add_target: ZIG_TARGET is required")
    endif()

    set(_src_dir "${CMAKE_CURRENT_FUNCTION_LIST_DIR}")
    set(_prefix "${CMAKE_CURRENT_BINARY_DIR}/ghostty-${_GVT_NAME}")

    # Build flags
    set(_flags
        -Demit-lib-vt
        -Dtarget=${_GVT_ZIG_TARGET}
        --prefix "${_prefix}"
    )

    # Default to ReleaseFast when no build type is set. Debug builds enable
    # UBSan in zig, and the sanitizer runtime is not available for all
    # cross-compilation targets.
    if(_GHOSTTY_ZIG_OPT_FLAG)
        list(APPEND _flags "${_GHOSTTY_ZIG_OPT_FLAG}")
    else()
        list(APPEND _flags "-Doptimize=ReleaseFast")
    endif()

    if(_GVT_ZIG_FLAGS)
        list(APPEND _flags ${_GVT_ZIG_FLAGS})
    endif()

    # Output paths
    set(_include_dir "${_prefix}/include")

    if(_GVT_ZIG_TARGET MATCHES "windows")
        set(_static_lib "${_prefix}/lib/ghostty-vt-static.lib")
        set(_shared_lib "${_prefix}/bin/ghostty-vt.dll")
        set(_implib "${_prefix}/lib/ghostty-vt.lib")
    elseif(_GVT_ZIG_TARGET MATCHES "darwin|macos")
        set(_static_lib "${_prefix}/lib/libghostty-vt.a")
        set(_shared_lib "${_prefix}/lib/libghostty-vt.0.1.0.dylib")
    else()
        set(_static_lib "${_prefix}/lib/libghostty-vt.a")
        set(_shared_lib "${_prefix}/lib/libghostty-vt.so.0.1.0")
    endif()

    file(MAKE_DIRECTORY "${_include_dir}")

    # Custom command: invoke zig build
    add_custom_command(
        OUTPUT "${_static_lib}" "${_shared_lib}"
        COMMAND "${ZIG_EXECUTABLE}" build ${_flags}
        WORKING_DIRECTORY "${_src_dir}"
        COMMENT "Building libghostty-vt for ${_GVT_ZIG_TARGET}..."
        USES_TERMINAL
    )

    set(_build_target "zig_build_lib_vt_${_GVT_NAME}")
    add_custom_target(${_build_target} ALL
        DEPENDS "${_static_lib}" "${_shared_lib}"
    )

    # Static target
    set(_static_target "ghostty-vt-static-${_GVT_NAME}")
    add_library(${_static_target} STATIC IMPORTED GLOBAL)
    set_target_properties(${_static_target} PROPERTIES
        IMPORTED_LOCATION "${_static_lib}"
        INTERFACE_INCLUDE_DIRECTORIES "${_include_dir}"
        INTERFACE_COMPILE_DEFINITIONS "GHOSTTY_STATIC"
    )
    if(_GVT_ZIG_TARGET MATCHES "windows")
        set_target_properties(${_static_target} PROPERTIES
            INTERFACE_LINK_LIBRARIES "ntdll;kernel32"
        )
    endif()
    add_dependencies(${_static_target} ${_build_target})

    # Shared target
    set(_shared_target "ghostty-vt-${_GVT_NAME}")
    add_library(${_shared_target} SHARED IMPORTED GLOBAL)
    set_target_properties(${_shared_target} PROPERTIES
        IMPORTED_LOCATION "${_shared_lib}"
        INTERFACE_INCLUDE_DIRECTORIES "${_include_dir}"
    )
    if(_GVT_ZIG_TARGET MATCHES "windows")
        set_target_properties(${_shared_target} PROPERTIES
            IMPORTED_IMPLIB "${_implib}"
        )
    elseif(_GVT_ZIG_TARGET MATCHES "darwin|macos")
        set_target_properties(${_shared_target} PROPERTIES
            IMPORTED_SONAME "@rpath/libghostty-vt.0.dylib"
        )
    else()
        set_target_properties(${_shared_target} PROPERTIES
            IMPORTED_SONAME "libghostty-vt.so.0"
        )
    endif()
    add_dependencies(${_shared_target} ${_build_target})
endfunction()
