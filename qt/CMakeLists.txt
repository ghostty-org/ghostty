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

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

include(GNUInstallDirs)

find_package(Qt6 REQUIRED COMPONENTS Gui Widgets OpenGL DBus
  Multimedia Svg WaylandClient)
# WindowBlur + XkbTracker use qpa/qplatformnativeinterface.h to reach
# the wl_display / wl_surface / wl_seat for native compositor calls
# (blur, layer-shell screen pinning, raw wl_keyboard listeners). The
# Qt-internal GuiPrivate module is tied to a specific
# Qt build, but every consumer of these headers ends up here — there
# is no public alternative. Suppress the cosmetic
# `_qt_internal_show_private_module_warning` so the build is silent
# unless something genuinely fails. Detect the component when
# present; some distros ship the headers without the matching
# CMake config (older Debian) and we fall back to hand-wiring the
# include dir below.
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 QUIET OPTIONAL_COMPONENTS GuiPrivate WaylandClientPrivate)

# LayerShellQt: the quick terminal is a wlr-layer-shell dropdown window.
find_package(LayerShellQt REQUIRED)

# KWin background-blur is applied through the native compositor via
# the org_kde_kwin_blur Wayland protocol. Qt6::GuiPrivate gives the
# QPA native-handle accessors.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
# libEGL for the OpenGL present path's dmabuf export
# (EGL_MESA_image_dma_buf_export). Resolved at runtime via
# eglGetProcAddress, so we only need the link for the base entry
# points (eglQueryString, eglGetCurrentDisplay, eglGetError).
pkg_check_modules(EGL REQUIRED IMPORTED_TARGET egl)
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

# Generate client glue for the linux-dmabuf-v1 protocol (used by the
# Vulkan present path: wrap libghostty's dmabuf fd in a wl_buffer and
# attach it to the wayland::SubsurfacePresenter's wl_surface). Vendored
# in qt/protocols/ so the build doesn't depend on
# /usr/share/wayland-protocols being installed.
set(DMABUF_XML "${CMAKE_CURRENT_SOURCE_DIR}/protocols/linux-dmabuf-v1.xml")
set(DMABUF_HEADER "${CMAKE_CURRENT_BINARY_DIR}/linux-dmabuf-v1-client-protocol.h")
set(DMABUF_CODE "${CMAKE_CURRENT_BINARY_DIR}/linux-dmabuf-v1-protocol.c")
add_custom_command(OUTPUT "${DMABUF_HEADER}"
  COMMAND "${WAYLAND_SCANNER}" client-header "${DMABUF_XML}" "${DMABUF_HEADER}"
  DEPENDS "${DMABUF_XML}" VERBATIM)
add_custom_command(OUTPUT "${DMABUF_CODE}"
  COMMAND "${WAYLAND_SCANNER}" private-code "${DMABUF_XML}" "${DMABUF_CODE}"
  DEPENDS "${DMABUF_XML}" VERBATIM)

# wp_viewporter — lets the presenter set a destination size in
# surface-local coords, decoupling the buffer's pixel dimensions
# from how big the subsurface appears on screen. Needed for
# fractional scaling.
set(VIEWPORTER_XML "${CMAKE_CURRENT_SOURCE_DIR}/protocols/viewporter.xml")
set(VIEWPORTER_HEADER "${CMAKE_CURRENT_BINARY_DIR}/viewporter-client-protocol.h")
set(VIEWPORTER_CODE "${CMAKE_CURRENT_BINARY_DIR}/viewporter-protocol.c")
add_custom_command(OUTPUT "${VIEWPORTER_HEADER}"
  COMMAND "${WAYLAND_SCANNER}" client-header "${VIEWPORTER_XML}" "${VIEWPORTER_HEADER}"
  DEPENDS "${VIEWPORTER_XML}" VERBATIM)
add_custom_command(OUTPUT "${VIEWPORTER_CODE}"
  COMMAND "${WAYLAND_SCANNER}" private-code "${VIEWPORTER_XML}" "${VIEWPORTER_CODE}"
  DEPENDS "${VIEWPORTER_XML}" VERBATIM)

# wp_fractional_scale_v1 — compositor sends the per-surface
# preferred fractional scale (in 120ths). We use this as the
# authoritative scale for sizing the buffer, instead of trusting
# Qt's devicePixelRatioF() (which is the same value, but going
# direct to the protocol avoids any sync lag with Qt's update).
set(FRACSCALE_XML "${CMAKE_CURRENT_SOURCE_DIR}/protocols/fractional-scale-v1.xml")
set(FRACSCALE_HEADER "${CMAKE_CURRENT_BINARY_DIR}/fractional-scale-v1-client-protocol.h")
set(FRACSCALE_CODE "${CMAKE_CURRENT_BINARY_DIR}/fractional-scale-v1-protocol.c")
add_custom_command(OUTPUT "${FRACSCALE_HEADER}"
  COMMAND "${WAYLAND_SCANNER}" client-header "${FRACSCALE_XML}" "${FRACSCALE_HEADER}"
  DEPENDS "${FRACSCALE_XML}" VERBATIM)
add_custom_command(OUTPUT "${FRACSCALE_CODE}"
  COMMAND "${WAYLAND_SCANNER}" private-code "${FRACSCALE_XML}" "${FRACSCALE_CODE}"
  DEPENDS "${FRACSCALE_XML}" VERBATIM)

# libghostty is built out-of-tree by Zig.
get_filename_component(GHOSTTY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(GHOSTTY_LIB_DIR "${GHOSTTY_ROOT}/zig-out/lib")
set(GHOSTTY_SO "${GHOSTTY_LIB_DIR}/ghostty-internal.so")

# Variant: which renderer libghostty was built with. Drives the
# installed executable name and (for the Vulkan variant) the
# libghostty install location, so the two builds can coexist
# side-by-side under the same `~/.local` prefix:
#
#   GHASTTY_VARIANT=opengl (default) →
#       ~/.local/bin/ghastty
#       ~/.local/lib/libghostty.so
#   GHASTTY_VARIANT=vulkan →
#       ~/.local/bin/ghastty-vulkan
#       ~/.local/lib/ghastty-vulkan/libghostty.so
#       (and the binary's INSTALL_RPATH points into the subdir
#        so the two .so files never conflict.)
#
# Set via `cmake -DGHASTTY_VARIANT=vulkan -S qt -B qt/build-vulkan`.
set(GHASTTY_VARIANT "opengl" CACHE STRING
    "Renderer variant: opengl (default) or vulkan")
set_property(CACHE GHASTTY_VARIANT PROPERTY STRINGS opengl vulkan)
if(GHASTTY_VARIANT STREQUAL "vulkan")
  set(GHASTTY_EXE_NAME "ghastty-vulkan")
  set(GHASTTY_LIB_SUBDIR "ghastty-vulkan")
  message(STATUS "Building Vulkan variant — exe=${GHASTTY_EXE_NAME}, lib=lib/${GHASTTY_LIB_SUBDIR}/")
else()
  set(GHASTTY_EXE_NAME "ghastty")
  set(GHASTTY_LIB_SUBDIR "")
endif()

# Compile-time renderer pick. Each binary is linked against exactly
# one libghostty.so variant (opengl or vulkan), so the renderer
# choice is inherent to the binary — no need for a runtime env var.
# GhosttySurface.cpp branches on GHASTTY_USE_VULKAN to spin up the
# Vulkan host vs the OpenGL context.
if(GHASTTY_VARIANT STREQUAL "vulkan")
  add_compile_definitions(GHASTTY_USE_VULKAN)
endif()

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
  src/vulkan/Host.cpp
  src/actions/ActionDispatcher.cpp
  src/actions/ChromeActions.cpp
  src/actions/InputActions.cpp
  src/actions/SplitActions.cpp
  src/actions/SystemActions.cpp
  src/actions/TabActions.cpp
  src/actions/WindowActions.cpp
  src/app/GhosttyApp.cpp
  src/bell/BellPlayer.cpp
  src/config/Config.cpp
  src/CommandPalette.cpp
  src/GhosttySurface.cpp
  src/GlobalShortcuts.cpp
  src/InspectorWindow.cpp
  src/input/XkbState.cpp
  src/MainWindow.cpp
  src/OverlayScrollbar.cpp
  src/quickterm/QuickTerminal.cpp
  src/SearchBar.cpp
  src/TabWidget.cpp
  src/undo/UndoStack.cpp
  src/Util.cpp
  src/wayland/EglDmabufTarget.cpp
  src/wayland/SubsurfacePresenter.cpp
  src/WindowBlur.cpp
  src/XkbTracker.cpp
  "${BLUR_CODE}"
  "${BLUR_HEADER}"
  "${DMABUF_CODE}"
  "${DMABUF_HEADER}"
  "${VIEWPORTER_CODE}"
  "${VIEWPORTER_HEADER}"
  "${FRACSCALE_CODE}"
  "${FRACSCALE_HEADER}"
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
  PkgConfig::XKBCOMMON
  PkgConfig::EGL
  LayerShellQt::Interface
  vulkan
  "${GHOSTTY_LINK_SO}"
)

# Hook up the private QPA headers (see find_package above).
#
# Qt6::WaylandClientPrivate gives us QtWaylandClient::QWaylandWindow,
# which we cast the QPA platform window to in GhosttySurface to call
# `commit()` directly — that forces a parent wl_surface commit at the
# moment our subsurface state is ready, instead of waiting on Qt's
# backing-store flush which never fires for our translucent widget.
if(TARGET Qt6::WaylandClientPrivate)
  target_link_libraries(ghastty PRIVATE Qt6::WaylandClientPrivate)
endif()
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
# Vulkan variant lives at lib/ghastty-vulkan/libghostty.so so it can
# coexist with the OpenGL build's lib/libghostty.so under the same
# install prefix. The INSTALL_RPATH steers each variant's binary at
# its own .so without polluting the other's lookup.
if(GHASTTY_VARIANT STREQUAL "vulkan")
  set(GHASTTY_INSTALL_RPATH
      "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}/${GHASTTY_LIB_SUBDIR}")
  set(GHASTTY_LIB_INSTALL_DIR
      "${CMAKE_INSTALL_LIBDIR}/${GHASTTY_LIB_SUBDIR}")
else()
  set(GHASTTY_INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}")
  set(GHASTTY_LIB_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}")
endif()

set_target_properties(ghastty PROPERTIES
  OUTPUT_NAME "${GHASTTY_EXE_NAME}"
  BUILD_RPATH "${GHOSTTY_LINK_DIR};${GHOSTTY_LIB_DIR}"
  INSTALL_RPATH "${GHASTTY_INSTALL_RPATH}"
)

# --- install ---------------------------------------------------------
install(TARGETS ghastty RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

# libghostty.so the binary links against (SONAME is libghostty.so).
install(FILES "${GHOSTTY_SO}"
  DESTINATION "${GHASTTY_LIB_INSTALL_DIR}"
  RENAME libghostty.so)

# Desktop entry + icon: only install for the OpenGL variant — the
# Vulkan binary is a developer-facing side-by-side build, not a
# user-facing app. Avoids duplicating the .desktop file with a
# different Exec= line.
if(GHASTTY_VARIANT STREQUAL "opengl")
  install(FILES dist/ghastty.desktop
    DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")

  # The custom scalable app icon.
  install(FILES dist/ghastty.svg
    DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps")
endif()
