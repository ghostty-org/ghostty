//! DBus helper for IPC
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const ApprtApp = @import("../App.zig");

/// The target for this IPC.
target: apprt.ipc.Target,

/// Connection to the DBus session bus.
dbus: *gio.DBusConnection,

/// The bus name of the Ghostty instance that we are calling.
bus_name: [:0]const u8,

/// The object path of the Ghostty instance that we are calling.
object_path: [:0]const u8,

/// Used to build the DBus payload.
payload_builder: *glib.VariantBuilder,

/// Used to build the parameters for the IPC.
parameters_builder: *glib.VariantBuilder,

/// Initialize the helper.
pub fn init(alloc: Allocator, target: apprt.ipc.Target, action: [:0]const u8) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!Self {

    // Get the appropriate bus name and object path for contacting the
    // Ghostty instance we're interested in.
    const bus_name: [:0]const u8, const object_path: [:0]const u8 = switch (target) {
        .class => |class| result: {
            // Force the usage of the class specified on the CLI to determine the
            // bus name and object path.
            const object_path = try std.fmt.allocPrintZ(alloc, "/{s}", .{class});

            std.mem.replaceScalar(u8, object_path, '.', '/');
            std.mem.replaceScalar(u8, object_path, '-', '_');

            break :result .{ class, object_path };
        },
        .detect => .{ ApprtApp.application_id, ApprtApp.object_path },
    };
    errdefer {
        switch (target) {
            .class => alloc.free(object_path),
            .detect => {},
        }
    }

    if (gio.Application.idIsValid(bus_name.ptr) == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("D-Bus bus name is not valid: {s}\n", .{bus_name});
        return error.IPCFailed;
    }

    if (glib.Variant.isObjectPath(object_path.ptr) == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("D-Bus object path is not valid: {s}\n", .{object_path});
        return error.IPCFailed;
    }

    // Get a connection to the DBus session bus.
    const dbus = dbus: {
        var err_: ?*glib.Error = null;
        defer if (err_) |err| err.free();

        const dbus_ = gio.busGetSync(.session, null, &err_);
        if (err_) |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print(
                "Unable to establish connection to D-Bus session bus: {s}\n",
                .{err.f_message orelse "(unknown)"},
            );
            return error.IPCFailed;
        }

        break :dbus dbus_ orelse {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("gio.busGetSync returned null\n", .{});
            return error.IPCFailed;
        };
    };

    // Set up the payload builder.
    const payload_variant_type = glib.VariantType.new("(sava{sv})");
    defer glib.free(payload_variant_type);

    const payload_builder = glib.VariantBuilder.new(payload_variant_type);

    // Add the action name to the payload.
    {
        const s_variant_type = glib.VariantType.new("s");
        defer s_variant_type.free();

        const bytes = glib.Bytes.new(action.ptr, action.len + 1);
        defer bytes.unref();
        const value = glib.Variant.newFromBytes(s_variant_type, bytes, @intFromBool(true));

        payload_builder.addValue(value);
    }

    // Set up the parameter builder.
    const parameters_variant_type = glib.VariantType.new("av");
    defer parameters_variant_type.free();

    const parameters_builder = glib.VariantBuilder.new(parameters_variant_type);

    return .{
        .target = target,
        .dbus = dbus,
        .bus_name = bus_name,
        .object_path = object_path,
        .payload_builder = payload_builder,
        .parameters_builder = parameters_builder,
    };
}

/// Add a parameter to the IPC call.
pub fn addParameter(self: *Self, variant: *glib.Variant) void {
    self.parameters_builder.add("v", variant);
}

/// Send the IPC to the remote Ghostty. Once it completes, nothing further
/// should be done with this object other than call `deinit`.
pub fn send(self: *Self) (std.posix.WriteError || apprt.ipc.Errors)!void {
    // finish building the parameters
    const parameters = self.parameters_builder.end();

    // Add the parameters to the payload.
    self.payload_builder.addValue(parameters);

    // Add the platform data to the payload.
    {
        const platform_data_variant_type = glib.VariantType.new("a{sv}");
        defer platform_data_variant_type.free();

        self.payload_builder.open(platform_data_variant_type);
        defer self.payload_builder.close();

        // We have no platform data.
    }

    const payload = self.payload_builder.end();

    {
        var err_: ?*glib.Error = null;
        defer if (err_) |err| err.free();

        const result_ = self.dbus.callSync(
            self.bus_name,
            self.object_path,
            "org.gtk.Actions",
            "Activate",
            payload,
            null, // We don't care about the return type, we don't do anything with it.
            .{}, // no flags
            -1, // default timeout
            null, // not cancellable
            &err_,
        );
        defer if (result_) |result| result.unref();

        if (err_) |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print(
                "D-Bus method call returned an error err={s}\n",
                .{err.f_message orelse "(unknown)"},
            );
            return error.IPCFailed;
        }
    }
}

/// Free/unref any data held by this instance.
pub fn deinit(self: *Self, alloc: Allocator) void {
    switch (self.target) {
        .class => alloc.free(self.object_path),
        .detect => {},
    }
    self.parameters_builder.unref();
    self.payload_builder.unref();
    self.dbus.unref();
}
