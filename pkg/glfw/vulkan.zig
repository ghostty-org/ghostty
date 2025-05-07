const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Window = @import("Window.zig");

const internal_debug = @import("internal_debug.zig");

/// Sets the desired Vulkan `vkGetInstanceProcAddr` function.
///
/// This function sets the `vkGetInstanceProcAddr` function that GLFW will use for all
/// Vulkan related entry point queries.
///
/// This feature is mostly useful on macOS, if your copy of the Vulkan loader is in
/// a location where GLFW cannot find it through dynamic loading, or if you are still
/// using the static library version of the loader.
///
/// If set to `NULL`, GLFW will try to load the Vulkan loader dynamically by its standard
/// name and get this function from there.  This is the default behavior.
///
/// The standard name of the loader is `vulkan-1.dll` on Windows, `libvulkan.so.1` on
/// Linux and other Unix-like systems and `libvulkan.1.dylib` on macOS.  If your code is
/// also loading it via these names then you probably don't need to use this function.
///
/// The function address you set is never reset by GLFW, but it only takes effect during
/// initialization.  Once GLFW has been initialized, any updates will be ignored until the
/// library is terminated and initialized again.
///
/// remark: This function may be called before glfw.Init.
///
/// thread_safety: This function must only be called from the main thread.
pub fn initVulkanLoader(loader_function: ?VKGetInstanceProcAddr) void {
    c.glfwInitVulkanLoader(loader_function orelse null);
}

pub const VKGetInstanceProcAddr = *const fn (vk_instance: c.VkInstance, name: [*c]const u8) callconv(.c) ?VKProc;

/// Returns whether the Vulkan loader and an ICD have been found.
///
/// This function returns whether the Vulkan loader and any minimally functional ICD have been
/// found.
///
/// The availability of a Vulkan loader and even an ICD does not by itself guarantee that surface
/// creation or even instance creation is possible. Call glfw.getRequiredInstanceExtensions
/// to check whether the extensions necessary for Vulkan surface creation are available and
/// glfw.getPhysicalDevicePresentationSupport to check whether a queue family of a physical device
/// supports image presentation.
///
/// @return `true` if Vulkan is minimally available, or `false` otherwise.
///
/// @thread_safety This function may be called from any thread.
pub inline fn vulkanSupported() bool {
    internal_debug.assertInitialized();
    const supported = c.glfwVulkanSupported();
    return supported == c.GLFW_TRUE;
}

/// Returns the Vulkan instance extensions required by GLFW.
///
/// This function returns an array of names of Vulkan instance extensions required by GLFW for
/// creating Vulkan surfaces for GLFW windows. If successful, the list will always contain
/// `VK_KHR_surface`, so if you don't require any additional extensions you can pass this list
/// directly to the `VkInstanceCreateInfo` struct.
///
/// If Vulkan is not available on the machine, this function returns null and generates a
/// glfw.ErrorCode.APIUnavailable error. Call glfw.vulkanSupported to check whether Vulkan is at
/// least minimally available.
///
/// If Vulkan is available but no set of extensions allowing window surface creation was found,
/// this function returns null. You may still use Vulkan for off-screen rendering and compute work.
///
/// Possible errors include glfw.ErrorCode.APIUnavailable.
/// Returns null in the event of an error.
///
/// Additional extensions may be required by future versions of GLFW. You should check if any
/// extensions you wish to enable are already in the returned array, as it is an error to specify
/// an extension more than once in the `VkInstanceCreateInfo` struct.
///
/// @pointer_lifetime The returned array is allocated and freed by GLFW. You should not free it
/// yourself. It is guaranteed to be valid only until the library is terminated.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: vulkan_ext, glfwCreateWindowSurface
pub inline fn getRequiredInstanceExtensions() ?[][*:0]const u8 {
    internal_debug.assertInitialized();
    var count: u32 = 0;
    if (c.glfwGetRequiredInstanceExtensions(&count)) |extensions| return @as([*][*:0]const u8, @ptrCast(extensions))[0..count];
    return null;
}

/// Vulkan API function pointer type.
///
/// Generic function pointer used for returning Vulkan API function pointers.
///
/// see also: vulkan_proc, glfw.getInstanceProcAddress
pub const VKProc = *const fn () callconv(if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) .Stdcall else .C) void;

/// Returns the address of the specified Vulkan instance function.
///
/// This function returns the address of the specified Vulkan core or extension function for the
/// specified instance. If instance is set to null it can return any function exported from the
/// Vulkan loader, including at least the following functions:
///
/// - `vkEnumerateInstanceExtensionProperties`
/// - `vkEnumerateInstanceLayerProperties`
/// - `vkCreateInstance`
/// - `vkGetInstanceProcAddr`
///
/// If Vulkan is not available on the machine, this function returns null and generates a
/// glfw.ErrorCode.APIUnavailable error. Call glfw.vulkanSupported to check whether Vulkan is at
/// least minimally available.
///
/// This function is equivalent to calling `vkGetInstanceProcAddr` with a platform-specific query
/// of the Vulkan loader as a fallback.
///
/// @param[in] instance The Vulkan instance to query, or null to retrieve functions related to
///            instance creation.
/// @param[in] procname The ASCII encoded name of the function.
/// @return The address of the function, or null if an error occurred.
///
/// To maintain ABI compatability with the C glfwGetInstanceProcAddress, as it is commonly passed
/// into libraries expecting that exact ABI, this function does not return an error. Instead, if
/// glfw.ErrorCode.NotInitialized or glfw.ErrorCode.APIUnavailable would occur this function will panic.
/// You may check glfw.vulkanSupported prior to invoking this function.
///
/// @pointer_lifetime The returned function pointer is valid until the library is terminated.
///
/// @thread_safety This function may be called from any thread.
pub fn getInstanceProcAddress(vk_instance: ?*anyopaque, proc_name: [*:0]const u8) callconv(.c) ?VKProc {
    internal_debug.assertInitialized();
    if (c.glfwGetInstanceProcAddress(if (vk_instance) |v| @as(c.VkInstance, @ptrCast(v)) else null, proc_name)) |proc_address| return proc_address;
    return null;
}

/// Returns whether the specified queue family can present images.
///
/// This function returns whether the specified queue family of the specified physical device
/// supports presentation to the platform GLFW was built for.
///
/// If Vulkan or the required window surface creation instance extensions are not available on the
/// machine, or if the specified instance was not created with the required extensions, this
/// function returns `GLFW_FALSE` and generates a glfw.ErrorCode.APIUnavailable error. Call
/// glfw.vulkanSupported to check whether Vulkan is at least minimally available and
/// glfw.getRequiredInstanceExtensions to check what instance extensions are required.
///
/// @param[in] instance The instance that the physical device belongs to.
/// @param[in] device The physical device that the queue family belongs to.
/// @param[in] queuefamily The index of the queue family to query.
/// @return `true` if the queue family supports presentation, or `false` otherwise.
///
/// Possible errors include glfw.ErrorCode.APIUnavailable and glfw.ErrorCode.PlatformError.
/// Returns false in the event of an error.
///
/// macos: This function currently always returns `true`, as the `VK_MVK_macos_surface` and
/// 'VK_EXT_metal_surface' extension does not provide a `vkGetPhysicalDevice*PresentationSupport` type function.
///
/// @thread_safety This function may be called from any thread. For synchronization details of
/// Vulkan objects, see the Vulkan specification.
///
/// see also: vulkan_present
pub inline fn getPhysicalDevicePresentationSupport(
    vk_instance: *anyopaque,
    vk_physical_device: *anyopaque,
    queue_family: u32,
) bool {
    internal_debug.assertInitialized();
    return c.glfwGetPhysicalDevicePresentationSupport(
        @as(c.VkInstance, @ptrCast(vk_instance)),
        @as(c.VkPhysicalDevice, @ptrCast(vk_physical_device)),
        queue_family,
    ) == c.GLFW_TRUE;
}

/// Creates a Vulkan surface for the specified window.
///
/// This function creates a Vulkan surface for the specified window.
///
/// If the Vulkan loader or at least one minimally functional ICD were not found, this function
/// returns `VK_ERROR_INITIALIZATION_FAILED` and generates a glfw.ErrorCode.APIUnavailable error. Call
/// glfw.vulkanSupported to check whether Vulkan is at least minimally available.
///
/// If the required window surface creation instance extensions are not available or if the
/// specified instance was not created with these extensions enabled, this function returns `VK_ERROR_EXTENSION_NOT_PRESENT`
/// and generates a glfw.ErrorCode.APIUnavailable error. Call glfw.getRequiredInstanceExtensions to
/// check what instance extensions are required.
///
/// The window surface cannot be shared with another API so the window must have been created with
/// the client api hint set to `GLFW_NO_API` otherwise it generates a glfw.ErrorCode.InvalidValue error
/// and returns `VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`.
///
/// The window surface must be destroyed before the specified Vulkan instance. It is the
/// responsibility of the caller to destroy the window surface. GLFW does not destroy it for you.
/// Call `vkDestroySurfaceKHR` to destroy the surface.
///
/// @param[in] vk_instance The Vulkan instance to create the surface in.
/// @param[in] window The window to create the surface for.
/// @param[in] vk_allocation_callbacks The allocator to use, or null to use the default
/// allocator.
/// @param[out] surface Where to store the handle of the surface. This is set
/// to `VK_NULL_HANDLE` if an error occurred.
/// @return `VkResult` type, `VK_SUCCESS` if successful, or a Vulkan error code if an
/// error occurred.
///
/// Possible errors include glfw.ErrorCode.APIUnavailable, glfw.ErrorCode.PlatformError and glfw.ErrorCode.InvalidValue
/// Returns a bool indicating success.
///
/// If an error occurs before the creation call is made, GLFW returns the Vulkan error code most
/// appropriate for the error. Appropriate use of glfw.vulkanSupported and glfw.getRequiredInstanceExtensions
/// should eliminate almost all occurrences of these errors.
///
/// macos: GLFW prefers the `VK_EXT_metal_surface` extension, with the `VK_MVK_macos_surface`
/// extension as a fallback. The name of the selected extension, if any, is included in the array
/// returned by glfw.getRequiredInstanceExtensions.
///
/// macos: This function currently only supports the `VK_MVK_macos_surface` extension from MoltenVK.
///
/// macos: This function creates and sets a `CAMetalLayer` instance for the window content view,
/// which is required for MoltenVK to function.
///
/// x11: By default GLFW prefers the `VK_KHR_xcb_surface` extension, with the `VK_KHR_xlib_surface`
/// extension as a fallback. You can make `VK_KHR_xlib_surface` the preferred extension by setting
/// glfw.InitHints.x11_xcb_vulkan_surface. The name of the selected extension, if any, is included
/// in the array returned by glfw.getRequiredInstanceExtensions.
///
/// @thread_safety This function may be called from any thread. For synchronization details of
/// Vulkan objects, see the Vulkan specification.
///
/// see also: vulkan_surface, glfw.getRequiredInstanceExtensions
pub inline fn createWindowSurface(vk_instance: anytype, window: Window, vk_allocation_callbacks: anytype, vk_surface_khr: anytype) i32 {
    internal_debug.assertInitialized();
    // zig-vulkan uses enums to represent opaque pointers:
    // pub const Instance = enum(usize) { null_handle = 0, _ };
    const instance: c.VkInstance = switch (@import("shims.zig").typeInfo(@TypeOf(vk_instance))) {
        .@"enum" => @as(c.VkInstance, @ptrFromInt(@intFromEnum(vk_instance))),
        else => @as(c.VkInstance, @ptrCast(vk_instance)),
    };

    return c.glfwCreateWindowSurface(
        instance,
        window.handle,
        if (vk_allocation_callbacks == null) null else @as(*const c.VkAllocationCallbacks, @ptrCast(@alignCast(vk_allocation_callbacks))),
        @as(*c.VkSurfaceKHR, @ptrCast(@alignCast(vk_surface_khr))),
    );
}

test "vulkanSupported" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    _ = glfw.vulkanSupported();
}

test "getRequiredInstanceExtensions" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    _ = glfw.getRequiredInstanceExtensions();
}

test "getInstanceProcAddress" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    // syntax check only, we don't have a real vulkan instance and so this function would panic.
    _ = glfw.getInstanceProcAddress;
}

test "syntax" {
    // Best we can do for these two functions in terms of testing in lieu of an actual Vulkan
    // context.
    _ = getPhysicalDevicePresentationSupport;
    _ = createWindowSurface;
    _ = initVulkanLoader;
}
