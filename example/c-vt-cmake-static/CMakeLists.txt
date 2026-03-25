cmake_minimum_required(VERSION 3.19)
project(c-vt-cmake-static LANGUAGES C)

include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG main
)
set(GHOSTTY_ZIG_BUILD_FLAGS "-Dsimd=false" CACHE STRING "" FORCE)
FetchContent_MakeAvailable(ghostty)

add_executable(c_vt_cmake_static src/main.c)
target_link_libraries(c_vt_cmake_static PRIVATE ghostty-vt-static)
