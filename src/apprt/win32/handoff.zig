//! Receives console sessions from Windows.
//!
//! When Ghostty is the default terminal, Windows starts it with `-Embedding`
//! and a console host asks it, through COM, to take over a session that is
//! already running. This file is the COM side of that conversation: a class
//! factory and the `ITerminalHandoff3` object it hands out.
const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.win32_handoff);

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn eql(self: *const Guid, other: *const Guid) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(other));
    }

    /// Parse "6F23DA90-15C5-4203-9DB0-64E73F1B1B00" at compile time.
    pub fn parse(comptime text: []const u8) Guid {
        comptime {
            if (text.len != 36) @compileError("GUID must be 36 characters");
            var guid: Guid = undefined;
            guid.data1 = std.fmt.parseInt(u32, text[0..8], 16) catch unreachable;
            guid.data2 = std.fmt.parseInt(u16, text[9..13], 16) catch unreachable;
            guid.data3 = std.fmt.parseInt(u16, text[14..18], 16) catch unreachable;
            guid.data4[0] = std.fmt.parseInt(u8, text[19..21], 16) catch unreachable;
            guid.data4[1] = std.fmt.parseInt(u8, text[21..23], 16) catch unreachable;
            for (0..6) |i| {
                const begin = 24 + i * 2;
                guid.data4[2 + i] = std.fmt.parseInt(u8, text[begin .. begin + 2], 16) catch unreachable;
            }
            return guid;
        }
    }
};

/// The class Windows is told to start for a handoff. Registered in
/// HKCU\Software\Classes\CLSID and named in HKCU\Console\%%Startup.
pub const clsid = Guid.parse("D716D648-B6E3-47F4-B00A-19C501244566");

const iid_unknown = Guid.parse("00000000-0000-0000-C000-000000000046");
const iid_class_factory = Guid.parse("00000001-0000-0000-C000-000000000046");
const iid_terminal_handoff3 = Guid.parse("6F23DA90-15C5-4203-9DB0-64E73F1B1B00");

const HRESULT = i32;
const S_OK: HRESULT = 0;
const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));

const COINIT_APARTMENTTHREADED = 0x2;
const CLSCTX_LOCAL_SERVER = 0x4;
const REGCLS_MULTIPLEUSE = 1;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoRegisterClassObject(
    class_id: *const Guid,
    unknown: *anyopaque,
    context: u32,
    flags: u32,
    cookie: *u32,
) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(cookie: u32) callconv(.winapi) HRESULT;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;

/// The struct COM passes as the last argument of `EstablishPtyHandoff`.
pub const StartupInfo = extern struct {
    title: ?[*:0]const u16,
    icon_path: ?[*:0]const u16,
    icon_index: i32,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_count_chars: u32,
    y_count_chars: u32,
    fill_attribute: u32,
    flags: u32,
    show_window: u16,
};

/// Called with the handles of a session Windows wants us to host. It runs
/// inside a COM call, so it must return quickly and leave real work for the
/// main message loop. The handles in `request` are owned by the callee.
pub const Handler = *const fn (context: *anyopaque, request: Request) HRESULT;

pub const Request = struct {
    /// Windows reads from this end. We write the user's keystrokes to it.
    /// Set by the handler.
    input_to_host: *?c.Handle,
    /// Windows writes the program's output to this end. Set by the handler.
    output_from_host: *?c.Handle,
    signal: c.Handle,
    reference: c.Handle,
    server: c.Handle,
    client: c.Handle,
    startup: ?*const StartupInfo,
};

var handler_fn: ?Handler = null;
var handler_context: ?*anyopaque = null;
var registration: u32 = 0;
var com_initialized = false;

/// True when Windows started us to receive a handoff, which it signals by
/// adding `-Embedding` to the command line.
pub fn isEmbedding() bool {
    const needle = c.utf16Literal("-Embedding");
    var cmd: [*:0]const u16 = GetCommandLineW();
    const text = std.mem.span(cmd);
    _ = &cmd;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.mem.eql(u16, text[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Start accepting handoffs. Must be called on the thread that runs the
/// message loop, because COM delivers calls as messages to this thread.
pub fn start(context: *anyopaque, handler: Handler) !void {
    handler_context = context;
    handler_fn = handler;

    const init_result = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (init_result < 0) return error.ComInitFailed;
    com_initialized = true;

    const result = CoRegisterClassObject(
        &clsid,
        &class_factory,
        CLSCTX_LOCAL_SERVER,
        REGCLS_MULTIPLEUSE,
        &registration,
    );
    if (result < 0) return error.ClassRegistrationFailed;
}

pub fn stop() void {
    if (registration != 0) _ = CoRevokeClassObject(registration);
    registration = 0;
    if (com_initialized) CoUninitialize();
    com_initialized = false;
}

// Both objects are static, so reference counting has nothing to free.

const ClassFactory = extern struct {
    vtable: *const Vtable,

    const Vtable = extern struct {
        query_interface: *const fn (*ClassFactory, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*ClassFactory) callconv(.winapi) u32,
        release: *const fn (*ClassFactory) callconv(.winapi) u32,
        create_instance: *const fn (*ClassFactory, ?*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
        lock_server: *const fn (*ClassFactory, i32) callconv(.winapi) HRESULT,
    };

    fn queryInterface(self: *ClassFactory, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (riid.eql(&iid_unknown) or riid.eql(&iid_class_factory)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(_: *ClassFactory) callconv(.winapi) u32 {
        return 2;
    }

    fn release(_: *ClassFactory) callconv(.winapi) u32 {
        return 1;
    }

    fn createInstance(
        _: *ClassFactory,
        outer: ?*anyopaque,
        riid: *const Guid,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        out.* = null;
        if (outer != null) return CLASS_E_NOAGGREGATION;

        log.info("handoff requested interface {x}-{x}-{x}", .{ riid.data1, riid.data2, riid.data3 });
        if (riid.eql(&iid_unknown) or riid.eql(&iid_terminal_handoff3)) {
            out.* = &handoff_object;
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    fn lockServer(_: *ClassFactory, _: i32) callconv(.winapi) HRESULT {
        return S_OK;
    }
};

const class_factory_vtable: ClassFactory.Vtable = .{
    .query_interface = ClassFactory.queryInterface,
    .add_ref = ClassFactory.addRef,
    .release = ClassFactory.release,
    .create_instance = ClassFactory.createInstance,
    .lock_server = ClassFactory.lockServer,
};
var class_factory: ClassFactory = .{ .vtable = &class_factory_vtable };

const HandoffObject = extern struct {
    vtable: *const Vtable,

    const Vtable = extern struct {
        query_interface: *const fn (*HandoffObject, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*HandoffObject) callconv(.winapi) u32,
        release: *const fn (*HandoffObject) callconv(.winapi) u32,
        establish_pty_handoff: *const fn (
            *HandoffObject,
            input: *?c.Handle,
            output: *?c.Handle,
            signal: c.Handle,
            reference: c.Handle,
            server: c.Handle,
            client: c.Handle,
            startup: ?*const StartupInfo,
        ) callconv(.winapi) HRESULT,
    };

    fn queryInterface(self: *HandoffObject, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (riid.eql(&iid_unknown) or riid.eql(&iid_terminal_handoff3)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(_: *HandoffObject) callconv(.winapi) u32 {
        return 2;
    }

    fn release(_: *HandoffObject) callconv(.winapi) u32 {
        return 1;
    }

    fn establishPtyHandoff(
        _: *HandoffObject,
        input: *?c.Handle,
        output: *?c.Handle,
        signal: c.Handle,
        reference: c.Handle,
        server: c.Handle,
        client: c.Handle,
        startup: ?*const StartupInfo,
    ) callconv(.winapi) HRESULT {
        const handler = handler_fn orelse return E_NOTIMPL;
        const context = handler_context orelse return E_NOTIMPL;
        return handler(context, .{
            .input_to_host = input,
            .output_from_host = output,
            .signal = signal,
            .reference = reference,
            .server = server,
            .client = client,
            .startup = startup,
        });
    }
};

const handoff_vtable: HandoffObject.Vtable = .{
    .query_interface = HandoffObject.queryInterface,
    .add_ref = HandoffObject.addRef,
    .release = HandoffObject.release,
    .establish_pty_handoff = HandoffObject.establishPtyHandoff,
};
var handoff_object: HandoffObject = .{ .vtable = &handoff_vtable };

test "GUID parsing" {
    const parsed = Guid.parse("6F23DA90-15C5-4203-9DB0-64E73F1B1B00");
    try std.testing.expectEqual(@as(u32, 0x6F23DA90), parsed.data1);
    try std.testing.expectEqual(@as(u16, 0x15C5), parsed.data2);
    try std.testing.expectEqual(@as(u16, 0x4203), parsed.data3);
    try std.testing.expectEqualSlices(u8, &.{ 0x9D, 0xB0, 0x64, 0xE7, 0x3F, 0x1B, 0x1B, 0x00 }, &parsed.data4);
}
