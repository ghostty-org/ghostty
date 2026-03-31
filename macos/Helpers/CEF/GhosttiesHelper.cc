// Entry point for CEF sub-processes (renderer, GPU, plugin, etc.).
// Must use the C++ API (CefExecuteProcess) to properly handle all
// Chromium subprocess command-line switches (--lang, --type, etc.).

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Load the CEF framework library at runtime.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  // Pass the real argc/argv so Chromium receives all its switches.
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
