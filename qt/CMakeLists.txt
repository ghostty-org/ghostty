cmake_minimum_required(VERSION 3.16)
# C is needed for the wayland-scanner-generated protocol code.
project(ghastty LANGUAGES CXX C)

# Ghastty: a Qt6 frontend for Ghostty that embeds libghostty through the
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
#   ./qt/build/ghastty
#   cmake --install qt/build --prefix ~/.local

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

include(GNUInstallDirs)

find_package(Qt6 REQUIRED COMPONENTS Gui Widgets OpenGL DBus
  Multimedia Svg)
# WindowBlur uses qpa/qplatformnativeinterface.h to reach the wl_display
# / wl_surface / xcb_connection_t for the native compositor blur calls.
# Qt's official path is `find_package(Qt6 COMPONENTS GuiPrivate)`, but
# Debian's qt6-base-private-dev ships the private headers without the
# matching Qt6GuiPrivateConfig.cmake. Detect the component when present;
# otherwise fall back to wiring the private include dir by hand.
find_package(Qt6 QUIET OPTIONAL_COMPONENTS GuiPrivate)

# LayerShellQt: the quick terminal is a wlr-layer-shell dropdown window.
find_package(LayerShellQt REQUIRED)

# KWin background-blur is applied through the native compositor: the
# org_kde_kwin_blur Wayland protocol and the _KDE_NET_WM_BLUR atom on
# X11. Qt6::GuiPrivate gives the QPA native-handle accessors.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
pkg_check_modules(XCB REQUIRED IMPORTED_TARGET xcb)
# libxkbcommon: derive the unshifted Unicode codepoint for a key event
# from its XKB keycode, so libghostty's kitty encoder finds an entry for
# punctuation keys (Qt's ev->key() reports the SHIFTED symbol, e.g.
# Qt::Key_Colon for Shift+;).
pkg_check_modules(XKBCOMMON REQUIRED IMPORTED_TARGET xkbcommon)
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
# ghostty-internal.so. Create a symlink in the build tree (NOT in the
# Zig output dir, which is the source tree from CMake's perspective)
# so the loader finds it under the SONAME the binary links against.
set(GHOSTTY_LINK_DIR "${CMAKE_CURRENT_BINARY_DIR}/lib")
set(GHOSTTY_LINK_SO "${GHOSTTY_LINK_DIR}/libghostty.so")
add_custom_command(OUTPUT "${GHOSTTY_LINK_SO}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${GHOSTTY_LINK_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E create_symlink
    "${GHOSTTY_SO}" "${GHOSTTY_LINK_SO}"
  DEPENDS "${GHOSTTY_SO}" VERBATIM)
add_custom_target(ghostty_link DEPENDS "${GHOSTTY_LINK_SO}")

add_executable(ghastty
  src/main.cpp
  src/CommandPalette.cpp
  src/GhosttySurface.cpp
  src/GlobalShortcuts.cpp
  src/InspectorWindow.cpp
  src/MainWindow.cpp
  src/OverlayScrollbar.cpp
  src/SearchBar.cpp
  src/TabWidget.cpp
  src/Util.cpp
  src/WindowBlur.cpp
  src/XkbTracker.cpp
  "${BLUR_CODE}"
  "${BLUR_HEADER}"
)

# Embed the app icon so it is available even running from the build tree.
qt_add_resources(ghastty "appicon"
  PREFIX "/"
  BASE dist
  FILES dist/ghastty.svg)

target_include_directories(ghastty PRIVATE
  "${GHOSTTY_ROOT}/include"
  "${CMAKE_CURRENT_BINARY_DIR}"  # generated blur-client-protocol.h
)

add_dependencies(ghastty ghostty_link)

target_link_libraries(ghastty PRIVATE
  Qt6::Gui
  Qt6::Widgets
  Qt6::OpenGL
  Qt6::DBus
  Qt6::Multimedia
  Qt6::Svg
  PkgConfig::WAYLAND_CLIENT
  PkgConfig::XCB
  PkgConfig::XKBCOMMON
  LayerShellQt::Interface
  "${GHOSTTY_LINK_SO}"
)

# Hook up the private QPA headers (see find_package above).
if(TARGET Qt6::GuiPrivate)
  target_link_libraries(ghastty PRIVATE Qt6::GuiPrivate)
else()
  # Debian fallback: locate qplatformnativeinterface.h and add its
  # parent dir as a private include (the header lives at
  # <prefix>/QtGui/<version>/QtGui/qpa/qplatformnativeinterface.h, so we
  # add the dir containing the `qpa` subfolder).
  # Multi-arch Debian uses ${CMAKE_LIBRARY_ARCHITECTURE} (e.g.
  # aarch64-linux-gnu) for include and lib subdirs. Hardcoding a list
  # missed armhf/riscv64; deriving from the toolchain handles every
  # arch the Qt 6 packages support.
  find_path(QT_QPA_INCLUDE_DIR
    NAMES qpa/qplatformnativeinterface.h
    HINTS
      "${Qt6Gui_PRIVATE_INCLUDE_DIRS}"
      "${Qt6_DIR}/../../../include/${CMAKE_LIBRARY_ARCHITECTURE}/qt6/QtGui/${Qt6_VERSION}/QtGui"
      "${Qt6_DIR}/../../../include/qt6/QtGui/${Qt6_VERSION}/QtGui"
    PATH_SUFFIXES
      "qt6/QtGui/${Qt6_VERSION}/QtGui"
  )
  if(NOT QT_QPA_INCLUDE_DIR)
    message(FATAL_ERROR
      "Qt6 private QPA headers not found.\n"
      "Install qt6-base-private-dev (Debian/Ubuntu) or the equivalent "
      "Qt 6 private headers package.")
  endif()
  message(STATUS "Using Qt private include dir: ${QT_QPA_INCLUDE_DIR}")
  target_include_directories(ghastty PRIVATE "${QT_QPA_INCLUDE_DIR}")
endif()

# RPATH:
# - Build tree: libghostty.so lives in our build dir (a symlink to the
#   actual zig-out artifact), and the .so's NEEDED entries also point
#   into zig-out/lib for transitive deps.
# - Installed: libghostty.so lives next to the binary ($ORIGIN/../lib).
set_target_properties(ghastty PROPERTIES
  BUILD_RPATH "${GHOSTTY_LINK_DIR};${GHOSTTY_LIB_DIR}"
  INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}"
)

# --- install ---------------------------------------------------------
install(TARGETS ghastty RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

# libghostty.so the binary links against (SONAME is libghostty.so).
install(FILES "${GHOSTTY_SO}"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  RENAME libghostty.so)

install(FILES dist/ghastty.desktop
  DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")

# The custom scalable app icon.
install(FILES dist/ghastty.svg
  DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps")
