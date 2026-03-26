using System.Runtime.InteropServices;

[assembly: System.Runtime.CompilerServices.DisableRuntimeMarshalling]

namespace Ghostty.Tests;

/// <summary>
/// Tests that validate libghostty DLL initialization on Windows.
///
/// Ghostty's main_c.zig declares a DllMain that calls __vcrt_initialize
/// and __acrt_initialize because Zig's _DllMainCRTStartup does not
/// initialize the MSVC C runtime for DLL targets. Without this, any C
/// library function (setlocale, glslang, oniguruma) crashes.
///
/// See the probe test at the bottom for workaround tracking.
/// </summary>
[TestClass]
public partial class LibghosttyInitTests
{
    private const string LibName = "ghostty";

    [StructLayout(LayoutKind.Sequential)]
    private struct GhosttyInfo
    {
        public int BuildMode;
        public nint Version;
        public nuint VersionLen;
    }

    [LibraryImport(LibName, EntryPoint = "ghostty_info")]
    private static partial GhosttyInfo GhosttyInfoNative();

    [LibraryImport(LibName, EntryPoint = "ghostty_crt_workaround_active")]
    private static partial int GhosttyWorkaroundActive();

    [TestMethod]
    public void GhosttyInfo_Works()
    {
        // Baseline: ghostty_info uses only compile-time constants and
        // does not depend on CRT state. This should always work.
        var info = GhosttyInfoNative();

        Assert.IsGreaterThan((nuint)0, info.VersionLen);
        Assert.AreNotEqual(nint.Zero, info.Version);
    }

    // NOTE: ghostty_init is validated by the C reproducer (test_dll_init.c)
    // rather than a C# test because ghostty_init initializes global state
    // (glslang, oniguruma, allocators) that crashes during test host
    // teardown when the DLL is unloaded. The C reproducer handles this by
    // exiting without FreeLibrary. The DLL unload ordering issue is
    // separate from the CRT init fix.

    /// <summary>
    /// PROBE TEST: Detects when our DllMain CRT workaround in main_c.zig
    /// is removed, which should happen when Zig fixes _DllMainCRTStartup
    /// for MSVC DLL targets.
    ///
    /// HOW IT WORKS:
    ///   ghostty_crt_workaround_active() returns 1 when the workaround is
    ///   compiled in (Windows MSVC), 0 on other platforms. This test
    ///   asserts that it returns 1. When it returns 0, the workaround was
    ///   removed.
    ///
    /// WHEN THIS TEST FAILS:
    ///   Someone removed the DllMain workaround from main_c.zig.
    ///   This is the expected outcome when Zig fixes the issue.
    ///
    ///   Step 1: Run test_dll_init.c (the C reproducer) WITHOUT the
    ///           DllMain workaround. If ghostty_init returns 0, Zig
    ///           fixed it. Delete the DllMain block in main_c.zig,
    ///           ghostty_crt_workaround_active(), and this probe test.
    ///
    ///   Step 2: If ghostty_init still crashes without the workaround,
    ///           restore the DllMain block in main_c.zig.
    ///
    ///   Step 3: To unblock CI while investigating, skip this test:
    ///     dotnet test --filter "FullyQualifiedName!=Ghostty.Tests.LibghosttyInitTests.DllMainWorkaround_IsStillActive"
    ///
    /// UPSTREAM TRACKING (as of 2026-03-26):
    ///   No Zig issue tracks this exact gap.
    ///   Closest: Codeberg ziglang/zig #30936 (reimplement crt0 code).
    ///   Related GitHub issues: 7065, 11285, 19672 (link-time, not runtime).
    /// </summary>
    [TestMethod]
    public void DllMainWorkaround_IsStillActive()
    {
        var active = GhosttyWorkaroundActive();
        Assert.AreEqual(1, active,
            "ghostty_crt_workaround_active() returned 0. " +
            "The DllMain CRT workaround in main_c.zig was removed or disabled. " +
            "Run test_dll_init.c without the workaround to check if Zig fixed " +
            "the issue. If ghostty_init works, delete the DllMain and this test. " +
            "If it crashes, restore the DllMain. " +
            "To skip this test: dotnet test --filter " +
            "\"FullyQualifiedName!=Ghostty.Tests.LibghosttyInitTests.DllMainWorkaround_IsStillActive\"");
    }
}
