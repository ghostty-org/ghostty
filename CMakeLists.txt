# CMake wrapper for libghostty-vt
#
# This file delegates to `zig build lib-vt` to produce the shared library,
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
#   target_link_libraries(myapp PRIVATE ghostty-vt)
#
# To use a local checkout instead of fetching:
#
#   cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=/path/to/ghostty
#
# Option 2 — find_package (after installing to a prefix):
#
#   find_package(ghostty-vt REQUIRED)
#   target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt)
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

# The library file that zig build produces.
if(APPLE)
    set(GHOSTTY_VT_LIBNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(GHOSTTY_VT_SONAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt.0${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(GHOSTTY_VT_REALNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt.0.1.0${CMAKE_SHARED_LIBRARY_SUFFIX}")
elseif(WIN32)
    set(GHOSTTY_VT_LIBNAME "ghostty-vt.dll")
    set(GHOSTTY_VT_REALNAME "ghostty-vt.dll")
else()
    set(GHOSTTY_VT_LIBNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(GHOSTTY_VT_SONAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}.0")
    set(GHOSTTY_VT_REALNAME "${CMAKE_SHARED_LIBRARY_PREFIX}ghostty-vt${CMAKE_SHARED_LIBRARY_SUFFIX}.0.1.0")
endif()

set(GHOSTTY_VT_LIBRARY "${ZIG_OUT_DIR}/lib/${GHOSTTY_VT_REALNAME}")

# Ensure the output directories exist so CMake doesn't reject the
# INTERFACE_INCLUDE_DIRECTORIES before the zig build has run.
file(MAKE_DIRECTORY "${ZIG_OUT_DIR}/include")

# Custom command: run zig build lib-vt
add_custom_command(
    OUTPUT "${GHOSTTY_VT_LIBRARY}"
    COMMAND "${ZIG_EXECUTABLE}" build lib-vt ${GHOSTTY_ZIG_BUILD_FLAGS}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building libghostty-vt via zig build..."
    USES_TERMINAL
)

add_custom_target(zig_build_lib_vt ALL DEPENDS "${GHOSTTY_VT_LIBRARY}")

# --- IMPORTED library target --------------------------------------------------

add_library(ghostty-vt SHARED IMPORTED GLOBAL)
set_target_properties(ghostty-vt PROPERTIES
    IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${ZIG_OUT_DIR}/include"
)
if(APPLE)
    set_target_properties(ghostty-vt PROPERTIES
        IMPORTED_SONAME "@rpath/${GHOSTTY_VT_SONAME}"
    )
elseif(NOT WIN32)
    set_target_properties(ghostty-vt PROPERTIES
        IMPORTED_SONAME "${GHOSTTY_VT_SONAME}"
    )
endif()

add_dependencies(ghostty-vt zig_build_lib_vt)

# --- Install ------------------------------------------------------------------

include(GNUInstallDirs)

# Install the library
install(FILES "${GHOSTTY_VT_LIBRARY}" TYPE LIB)
if(NOT WIN32)
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
