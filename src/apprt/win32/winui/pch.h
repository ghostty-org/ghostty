/// pch.h — Precompiled header for the WinUI 3 shim DLL.
///
/// Includes Windows headers and C++/WinRT projections for
/// Windows App SDK / WinUI 3.

#pragma once

// Target Windows 10 1809+ (XAML Islands minimum)
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

// Windows SDK
#include <windows.h>
#include <unknwn.h>

// C++/WinRT base (from Windows SDK cppwinrt headers)
#include <winrt/base.h>

// Windows foundation types
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>

// Windows graphics types (for RectInt32, etc.)
#include <winrt/Windows.Graphics.h>

// Windows UI types (for Color, TypeName in IXamlMetadataProvider)
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Xaml.Interop.h>

// Windows App SDK / WinUI 3 (generated projections)
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Media.Animation.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <winrt/Microsoft.UI.Content.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Input.h>

// MRT Core (Modern Resource Technology) for resource management
#include <winrt/Microsoft.Windows.ApplicationModel.Resources.h>

// WinUI 3 interop
#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Interop.h>
#include <Microsoft.UI.Interop.h>

// Standard library
#include <string>
#include <vector>
#include <memory>
