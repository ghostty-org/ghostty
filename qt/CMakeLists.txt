cmake_minimum_required(VERSION 3.16)
# C is needed for the wayland-scanner-generated protocol code.
project(ghostty LANGUAGES CXX C)

# A Qt6 frontend for Ghostty that embeds libghostty through the
# GHOSTTY_PLATFORM_OPENGL C API. libghostty's OpenGL renderer draws each
# terminal into an offscreen framebuffer (a private QOpenGLContext); the
# frame is read back into a QImage and painted on an ordinary translucent
# QWidget. That keeps the terminal a plain widget — it embeds in the
# tab/split tree and its transparent background composites like any other
# widget. libghostty draws on the GUI thread (the embedded apprt sets
# must_draw_from_app_thread for the OpenGL renderer).
#
# Build libghostty first, from the repo root. Use ReleaseFast: a Debug
# build of libghostty leaves the whole terminal core unoptimized and
# makes rendering and surface creation noticeably sluggish.
#
#   zig build -Dapp-runtime=none -Doptimize=ReleaseFast
#
# Then build, run, and (optionally) install this app:
#
#   cmake -S qt -B qt/build && cmake --build qt/build
#   ./qt/build/ghostty
#   cmake --install qt/build --prefix ~/.local

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

include(GNUInstallDirs)

find_package(Qt6 REQUIRED COMPONENTS Gui GuiPrivate Widgets OpenGL DBus
  Multimedia)

# KWin background-blur is applied through the native compositor: the
# org_kde_kwin_blur Wayland protocol and the _KDE_NET_WM_BLUR atom on
# X11. Qt6::GuiPrivate gives the QPA native-handle accessors.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
pkg_check_modules(XCB REQUIRED IMPORTED_TARGET xcb)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# Generate client glue for the org_kde_kwin_blur protocol.
set(BLUR_XML "${CMAKE_CURRENT_SOURCE_DIR}/protocols/blur.xml")
set(BLUR_HEADER "${CMAKE_CURRENT_BINARY_DIR}/blur-client-protocol.h")
set(BLUR_CODE "${CMAKE_CURRENT_BINARY_DIR}/blur-protocol.c")
add_custom_command(OUTPUT "${BLUR_HEADER}"
  COMMAND "${WAYLAND_SCANNER}" client-header "${BLUR_XML}" "${BLUR_HEADER}"
  DEPENDS "${BLUR_XML}" VERBATIM)
add_custom_command(OUTPUT "${BLUR_CODE}"
  COMMAND "${WAYLAND_SCANNER}" private-code "${BLUR_XML}" "${BLUR_CODE}"
  DEPENDS "${BLUR_XML}" VERBATIM)

# libghostty is built out-of-tree by Zig.
get_filename_component(GHOSTTY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(GHOSTTY_LIB_DIR "${GHOSTTY_ROOT}/zig-out/lib")
set(GHOSTTY_SO "${GHOSTTY_LIB_DIR}/ghostty-internal.so")

if(NOT EXISTS "${GHOSTTY_SO}")
  message(FATAL_ERROR
    "libghostty not found at ${GHOSTTY_SO}\n"
    "Build it first from the repo root: zig build -Dapp-runtime=none")
endif()

# The .so's SONAME is libghostty.so but it is installed as
# ghostty-internal.so; create the expected name so the loader finds it.
file(CREATE_LINK "ghostty-internal.so" "${GHOSTTY_LIB_DIR}/libghostty.so"
  SYMBOLIC)

add_executable(ghostty
  src/main.cpp
  src/CommandPalette.cpp
  src/GhosttySurface.cpp
  src/MainWindow.cpp
  src/SearchBar.cpp
  src/WindowBlur.cpp
  "${BLUR_CODE}"
  "${BLUR_HEADER}"
)

target_include_directories(ghostty PRIVATE
  "${GHOSTTY_ROOT}/include"
  "${CMAKE_CURRENT_BINARY_DIR}"  # generated blur-client-protocol.h
)

target_link_libraries(ghostty PRIVATE
  Qt6::Gui
  Qt6::GuiPrivate
  Qt6::Widgets
  Qt6::OpenGL
  Qt6::DBus
  Qt6::Multimedia
  PkgConfig::WAYLAND_CLIENT
  PkgConfig::XCB
  "${GHOSTTY_LIB_DIR}/libghostty.so"
)

# RPATH: the build-tree binary finds libghostty.so in zig-out/lib; the
# installed binary finds it next to itself ($ORIGIN/../lib).
set_target_properties(ghostty PROPERTIES
  BUILD_RPATH "${GHOSTTY_LIB_DIR}"
  INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}"
)

# --- install ---------------------------------------------------------
install(TARGETS ghostty RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

# libghostty.so the binary links against (SONAME is libghostty.so).
install(FILES "${GHOSTTY_SO}"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  RENAME libghostty.so)

install(FILES dist/ghostty.desktop
  DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")

# Reuse Ghostty's own PNG icons, installed into the hicolor theme.
foreach(sz 16 32 128 256 512)
  install(FILES "${GHOSTTY_ROOT}/images/icons/icon_${sz}.png"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/${sz}x${sz}/apps"
    RENAME ghostty.png)
endforeach()
