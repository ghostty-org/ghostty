cmake_minimum_required(VERSION 3.19)
project(c-vt-cmake LANGUAGES C)

include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG main
)
FetchContent_MakeAvailable(ghostty)

add_executable(c_vt_cmake src/main.c)
target_link_libraries(c_vt_cmake PRIVATE ghostty-vt)
