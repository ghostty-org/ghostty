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
# See dist/cmake/README.md for more details and example/c-vt-cmake/ for a
# complete working example.

cmake_minimum_required(VERSION 3.19)
project(ghostty-vt VERSION 0.1.0 LANGUAGES C)

# --- Options ----------------------------------------------------------------

set(GHOSTTY_ZIG_BUILD_FLAGS "" CACHE STRING "Additional flags to pass to zig build")

# Map CMake build types to Zig optimization levels.
if(CMAKE_BUILD_TYPE)
    string(TOUPPER "${CMAKE_BUILD_TYPE}" _bt)
    if(_bt STREQUAL "RELEASE" OR _bt STREQUAL "MINSIZEREL" OR _bt STREQUAL "RELWITHDEBINFO")
        list(APPEND GHOSTTY_ZIG_BUILD_FLAGS "-Doptimize=ReleaseFast")
    endif()
    unset(_bt)
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
# When linking the static library, consumers must also link its transitive
# dependencies. By default (with SIMD enabled), these are:
#   - libc
#   - libc++ (or libstdc++ on Linux)
#   - highway
#   - simdutf
#
# Building with -Dsimd=false removes the C++ / highway / simdutf
# dependencies, leaving only libc.
add_library(ghostty-vt-static STATIC IMPORTED GLOBAL)
set_target_properties(ghostty-vt-static PROPERTIES
    IMPORTED_LOCATION "${GHOSTTY_VT_STATIC_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${ZIG_OUT_DIR}/include"
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
