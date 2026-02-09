cmake_minimum_required(VERSION 3.20)
project(ghostty_winui LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
# ---------------------------------------------------------------
# Locate the Windows App SDK NuGet package
# ---------------------------------------------------------------

# Auto-detect from default NuGet cache if not set.
if(NOT DEFINED WINDOWS_APP_SDK_DIR)
      file(GLOB _sdk_dirs "$ENV{USERPROFILE}/.nuget/packages/microsoft.windowsappsdk/*/")
      if(_sdk_dirs)
            list(SORT _sdk_dirs ORDER DESCENDING)
            list(GET _sdk_dirs 0 WINDOWS_APP_SDK_DIR)
      endif()
endif()

if(NOT DEFINED WINDOWS_APP_SDK_DIR OR NOT EXISTS "${WINDOWS_APP_SDK_DIR}")
      message(FATAL_ERROR
        "Could not find Windows App SDK. Set WINDOWS_APP_SDK_DIR or install via:\n"
        "  nuget install Microsoft.WindowsAppSDK -OutputDirectory packages"
    )
endif()

message(STATUS "Using Windows App SDK: ${WINDOWS_APP_SDK_DIR}")

# ---------------------------------------------------------------
# Locate cppwinrt.exe from the Windows SDK
# ---------------------------------------------------------------

if(NOT DEFINED CPPWINRT_EXE)
      # Find from Windows SDK
      file(GLOB _cppwinrt_paths
        "C:/Program Files (x86)/Windows Kits/10/bin/*/x64/cppwinrt.exe"
    )
      if(_cppwinrt_paths)
            list(SORT _cppwinrt_paths ORDER DESCENDING)
            list(GET _cppwinrt_paths 0 CPPWINRT_EXE)
      endif()
endif()

if(NOT DEFINED CPPWINRT_EXE OR NOT EXISTS "${CPPWINRT_EXE}")
      message(FATAL_ERROR
        "Could not find cppwinrt.exe. Install the Windows SDK or set CPPWINRT_EXE."
    )
endif()

message(STATUS "Using cppwinrt.exe: ${CPPWINRT_EXE}")

# ---------------------------------------------------------------
# Detect Windows SDK version for system winmd
# ---------------------------------------------------------------

if(NOT DEFINED WIN_SDK_VERSION)
      file(GLOB _sdk_versions
        "C:/Program Files (x86)/Windows Kits/10/UnionMetadata/10.*/"
    )
      if(_sdk_versions)
            list(SORT _sdk_versions ORDER DESCENDING)
            list(GET _sdk_versions 0 _sdk_ver_dir)
            get_filename_component(WIN_SDK_VERSION "${_sdk_ver_dir}" NAME)
      endif()
endif()

if(NOT DEFINED WIN_SDK_VERSION)
      set(WIN_SDK_VERSION "10.0.26100.0")
endif()

message(STATUS "Windows SDK version: ${WIN_SDK_VERSION}")

set(WIN_SDK_ROOT "C:/Program Files (x86)/Windows Kits/10")
set(WIN_SDK_CPPWINRT "${WIN_SDK_ROOT}/Include/${WIN_SDK_VERSION}/cppwinrt")
set(WIN_SDK_WINMD "${WIN_SDK_ROOT}/UnionMetadata/${WIN_SDK_VERSION}")

# ---------------------------------------------------------------
# Generate C++/WinRT projection headers for WinApp SDK
# ---------------------------------------------------------------

set(GENERATED_DIR "${CMAKE_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

# Collect all .winmd files from the SDK
file(GLOB APP_SDK_WINMD "${WINDOWS_APP_SDK_DIR}/lib/uap10.0/*.winmd")

# Detect the best uap10.0.NNNNN sub-TFM that contains Microsoft.UI.winmd
# (has Microsoft.UI.Dispatching, Microsoft.Graphics, etc.)
file(GLOB _tfm_dirs "${WINDOWS_APP_SDK_DIR}/lib/uap10.0.*")
if(_tfm_dirs)
      list(SORT _tfm_dirs ORDER DESCENDING)
      list(GET _tfm_dirs 0 APP_SDK_TFM_DIR)
      message(STATUS "Windows App SDK sub-TFM: ${APP_SDK_TFM_DIR}")
endif()

# Locate WebView2 winmd (referenced by Microsoft.UI.Xaml.winmd)
if(NOT DEFINED WEBVIEW2_WINMD_DIR)
      file(GLOB _wv2_dirs "$ENV{USERPROFILE}/.nuget/packages/microsoft.web.webview2/*/lib")
      if(_wv2_dirs)
            list(SORT _wv2_dirs ORDER DESCENDING)
            list(GET _wv2_dirs 0 WEBVIEW2_WINMD_DIR)
      endif()
endif()

# Generate projections
set(CPPWINRT_STAMP "${GENERATED_DIR}/.cppwinrt_stamp")

# Build the cppwinrt command arguments
set(_CPPWINRT_ARGS
    -in "${WINDOWS_APP_SDK_DIR}/lib/uap10.0"
    -in "${APP_SDK_TFM_DIR}"
    -ref "${WIN_SDK_WINMD}"
    -out "${GENERATED_DIR}"
)
if(WEBVIEW2_WINMD_DIR AND EXISTS "${WEBVIEW2_WINMD_DIR}")
      # WebView2 projections needed because Microsoft.UI.Xaml.Controls references them
      list(APPEND _CPPWINRT_ARGS -in "${WEBVIEW2_WINMD_DIR}")
      message(STATUS "WebView2 winmd: ${WEBVIEW2_WINMD_DIR}")
endif()

add_custom_command(
    OUTPUT "${CPPWINRT_STAMP}"
    COMMAND "${CPPWINRT_EXE}" ${_CPPWINRT_ARGS}
    COMMAND ${CMAKE_COMMAND} -E touch "${CPPWINRT_STAMP}"
    DEPENDS ${APP_SDK_WINMD}
    COMMENT "Generating C++/WinRT projections for Windows App SDK"
    VERBATIM
)
add_custom_target(cppwinrt_projections DEPENDS "${CPPWINRT_STAMP}")

# ---------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------

if(CMAKE_SIZEOF_VOID_P EQUAL 8)
      set(APP_SDK_ARCH "win10-x64")
else()
      set(APP_SDK_ARCH "win10-x86")
endif()

# ---------------------------------------------------------------
# Build the DLL
# ---------------------------------------------------------------

add_library(ghostty_winui SHARED
    ghostty_winui.cpp
)

add_dependencies(ghostty_winui cppwinrt_projections)

target_precompile_headers(ghostty_winui PRIVATE pch.h)

target_include_directories(ghostty_winui PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    "${GENERATED_DIR}/winrt"          # Generated WinApp SDK projections
    "${GENERATED_DIR}"                # Generated root (for winrt/base.h etc.)
    "${WIN_SDK_CPPWINRT}"             # Windows SDK C++/WinRT headers
    "${WIN_SDK_CPPWINRT}/winrt"       # Windows SDK winrt/ subdirectory
    "${WINDOWS_APP_SDK_DIR}/include"  # WinApp SDK interop headers
)

target_compile_definitions(ghostty_winui PRIVATE
    GHOSTTY_WINUI_EXPORTS
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _SILENCE_ALL_CXX17_DEPRECATION_WARNINGS
    WINRT_LEAN_AND_MEAN
)

if(MSVC)
      target_compile_options(ghostty_winui PRIVATE /W3 /EHsc /bigobj)
else()
      target_compile_options(ghostty_winui PRIVATE -Wno-c++17-extensions)
endif()

# Link against Windows App SDK libs.
target_link_directories(ghostty_winui PRIVATE
    "${WINDOWS_APP_SDK_DIR}/lib/${APP_SDK_ARCH}"
)
target_link_libraries(ghostty_winui PRIVATE
    Microsoft.WindowsAppRuntime
    Microsoft.WindowsAppRuntime.Bootstrap
    windowsapp
    onecoreuap
)

# Output directory.
set_target_properties(ghostty_winui PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

# ---------------------------------------------------------------
# Generate resources.pri using makepri.exe
# ---------------------------------------------------------------
# WinUI controls require a resources.pri file to resolve theme resources
# (brushes, colors, etc.) from the Windows App SDK framework package.
# Without this, XamlControlsResources() fails with "Cannot find a resource
# with the given key: AcrylicBackgroundFillColorDefaultBrush".

# Find makepri.exe from the Windows SDK
if(NOT DEFINED MAKEPRI_EXE)
      file(GLOB _makepri_paths
        "C:/Program Files (x86)/Windows Kits/10/bin/*/x64/makepri.exe"
    )
      if(_makepri_paths)
            list(SORT _makepri_paths ORDER DESCENDING)
            list(GET _makepri_paths 0 MAKEPRI_EXE)
      endif()
endif()

# Find the WinAppSDK runtime .pri files (from the installed framework package)
set(_WINUI_PRI_DIR "")
file(GLOB _runtime_dirs
    "C:/Program Files/WindowsApps/Microsoft.WindowsAppRuntime.1.6_*_x64__8wekyb3d8bbwe"
)
if(_runtime_dirs)
      list(SORT _runtime_dirs ORDER DESCENDING)
      list(GET _runtime_dirs 0 _WINUI_PRI_DIR)
endif()

if(MAKEPRI_EXE AND _WINUI_PRI_DIR AND EXISTS "${_WINUI_PRI_DIR}/resources.pri")
      message(STATUS "makepri.exe: ${MAKEPRI_EXE}")
      message(STATUS "WinUI runtime PRI source: ${_WINUI_PRI_DIR}")

      # Copy the framework .pri files next to our DLL output.
      # The XAML resource system looks for these alongside the executable.
      set(_PRI_OUTPUT_DIR "${CMAKE_BINARY_DIR}/bin")
      add_custom_command(TARGET ghostty_winui POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${_WINUI_PRI_DIR}/resources.pri"
            "${_PRI_OUTPUT_DIR}/resources.pri"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${_WINUI_PRI_DIR}/Microsoft.UI.Xaml.Controls.pri"
            "${_PRI_OUTPUT_DIR}/Microsoft.UI.Xaml.Controls.pri"
        COMMENT "Copying WinUI resource files (.pri)"
        VERBATIM
    )
else()
      message(WARNING
        "Could not find makepri.exe or WinUI runtime .pri files. "
        "WinUI controls may render without Fluent styling."
    )
endif()
