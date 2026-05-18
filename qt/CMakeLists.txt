cmake_minimum_required(VERSION 3.16)
project(ghostty LANGUAGES CXX)

# A Qt6 frontend for Ghostty that embeds libghostty through the
# GHOSTTY_PLATFORM_OPENGL C API. libghostty's OpenGL renderer draws each
# terminal into an offscreen framebuffer (a private QOpenGLContext); the
# frame is read back into a QImage and painted on an ordinary translucent
# QWidget. That keeps the terminal a plain widget — it embeds in the
# tab/split tree and its transparent background composites like any other
# widget. libghostty draws on the GUI thread (the embedded apprt sets
# must_draw_from_app_thread for the OpenGL renderer).
#
# Build libghostty first, from the repo root:
#
#   zig build -Dapp-runtime=none -Doptimize=Debug
#
# Then build and run this app:
#
#   cmake -S qt -B qt/build && cmake --build qt/build
#   ./qt/build/ghostty

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Gui Widgets OpenGL)

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
  src/GhosttySurface.cpp
  src/MainWindow.cpp
)

target_include_directories(ghostty PRIVATE "${GHOSTTY_ROOT}/include")

target_link_libraries(ghostty PRIVATE
  Qt6::Gui
  Qt6::Widgets
  Qt6::OpenGL
  "${GHOSTTY_LIB_DIR}/libghostty.so"
)

target_link_options(ghostty PRIVATE
  "-Wl,-rpath,${GHOSTTY_LIB_DIR}"
)
