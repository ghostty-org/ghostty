const std = @import("std");
const Allocator = std.mem.Allocator;
const d3d11 = @import("d3d11.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a buffer.
pub const Options = struct {
    device: d3d11.ID3D11Device,
    context: d3d11.ID3D11DeviceContext,
    bind_flags: d3d11.D3D11_BIND_FLAG = d3d11.D3D11_BIND_VERTEX_BUFFER,
    structured: bool = false,
};

/// Combined buffer + SRV handle used by the generic renderer.
/// This is the type of `Buffer(T).buffer`, passed through to RenderPass.Step.
pub const BufferHandle = struct {
    buf: ?d3d11.ID3D11Buffer = null,
    srv: ?d3d11.ID3D11ShaderResourceView = null,
};

/// Direct3D 11 GPU buffer generic over element type T.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Combined buffer + SRV handle, used by generic renderer for step construction.
        buffer: BufferHandle = .{},

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length (number of T elements).
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            const actual_len = @max(len, 1);
            const byte_width: u32 = @intCast(actual_len * @sizeOf(T));

            var desc = d3d11.D3D11_BUFFER_DESC{
                .ByteWidth = byte_width,
                .Usage = .DYNAMIC,
                .BindFlags = opts.bind_flags,
                .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            };

            if (opts.structured) {
                desc.MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
                desc.StructureByteStride = @sizeOf(T);
            }

            var buf: ?d3d11.ID3D11Buffer = null;
            const hr = opts.device.CreateBuffer(&desc, null, &buf);
            if (d3d11.FAILED(hr)) {
                log.err("CreateBuffer failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return error.DirectXFailed;
            }

            var result = Self{
                .buffer = .{ .buf = buf },
                .opts = opts,
                .len = actual_len,
            };

            // Create SRV for structured buffers
            if (opts.structured) {
                result.buffer.srv = try createSRV(opts.device, buf.?, actual_len);
            }

            return result;
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            const actual_len = @max(data.len, 1);
            const byte_width: u32 = @intCast(actual_len * @sizeOf(T));

            var desc = d3d11.D3D11_BUFFER_DESC{
                .ByteWidth = byte_width,
                .Usage = .DYNAMIC,
                .BindFlags = opts.bind_flags,
                .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            };

            if (opts.structured) {
                desc.MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
                desc.StructureByteStride = @sizeOf(T);
            }

            const init_data: ?*const d3d11.D3D11_SUBRESOURCE_DATA = if (data.len > 0)
                &d3d11.D3D11_SUBRESOURCE_DATA{
                    .pSysMem = @ptrCast(data.ptr),
                }
            else
                null;

            var buf: ?d3d11.ID3D11Buffer = null;
            const hr = opts.device.CreateBuffer(&desc, init_data, &buf);
            if (d3d11.FAILED(hr)) {
                log.err("CreateBuffer (initFill) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return error.DirectXFailed;
            }

            var result = Self{
                .buffer = .{ .buf = buf },
                .opts = opts,
                .len = actual_len,
            };

            if (opts.structured) {
                result.buffer.srv = try createSRV(opts.device, buf.?, actual_len);
            }

            return result;
        }

        pub fn deinit(self: Self) void {
            if (self.buffer.srv) |srv| _ = srv.Release();
            if (self.buffer.buf) |buf| _ = buf.Release();
        }

        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len == 0) return;

            // Recreate if buffer is too small
            if (data.len > self.len) {
                if (self.buffer.srv) |srv| _ = srv.Release();
                if (self.buffer.buf) |b| _ = b.Release();

                const new_len = data.len * 2;
                const byte_width: u32 = @intCast(new_len * @sizeOf(T));

                var desc = d3d11.D3D11_BUFFER_DESC{
                    .ByteWidth = byte_width,
                    .Usage = .DYNAMIC,
                    .BindFlags = self.opts.bind_flags,
                    .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
                };

                if (self.opts.structured) {
                    desc.MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
                    desc.StructureByteStride = @sizeOf(T);
                }

                var buf: ?d3d11.ID3D11Buffer = null;
                const hr = self.opts.device.CreateBuffer(&desc, null, &buf);
                if (d3d11.FAILED(hr)) {
                    log.err("CreateBuffer (resize) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
                    self.buffer = .{};
                    return error.DirectXFailed;
                }

                self.buffer.buf = buf;
                self.len = new_len;

                if (self.opts.structured) {
                    self.buffer.srv = try createSRV(self.opts.device, buf.?, new_len);
                } else {
                    self.buffer.srv = null;
                }
            }

            // Map, copy, unmap
            const buf = self.buffer.buf orelse return;
            var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = .{};
            const hr = self.opts.context.Map(
                @ptrCast(buf),
                0,
                .WRITE_DISCARD,
                0,
                &mapped,
            );
            if (d3d11.FAILED(hr)) {
                log.warn("Map failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return error.DirectXFailed;
            }

            const dest: [*]u8 = @ptrCast(mapped.pData orelse {
                self.opts.context.Unmap(@ptrCast(buf), 0);
                return error.DirectXFailed;
            });
            const src = std.mem.sliceAsBytes(data);
            @memcpy(dest[0..src.len], src);

            self.opts.context.Unmap(@ptrCast(buf), 0);
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            if (total_len == 0) return 0;

            // Recreate if buffer is too small
            if (total_len > self.len) {
                if (self.buffer.srv) |srv| _ = srv.Release();
                if (self.buffer.buf) |b| _ = b.Release();

                const new_len = total_len * 2;
                const byte_width: u32 = @intCast(new_len * @sizeOf(T));

                var desc = d3d11.D3D11_BUFFER_DESC{
                    .ByteWidth = byte_width,
                    .Usage = .DYNAMIC,
                    .BindFlags = self.opts.bind_flags,
                    .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
                };

                if (self.opts.structured) {
                    desc.MiscFlags = d3d11.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
                    desc.StructureByteStride = @sizeOf(T);
                }

                var buf: ?d3d11.ID3D11Buffer = null;
                const hr = self.opts.device.CreateBuffer(&desc, null, &buf);
                if (d3d11.FAILED(hr)) {
                    log.err("CreateBuffer (syncFromArrayLists resize) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
                    self.buffer = .{};
                    return error.DirectXFailed;
                }

                self.buffer.buf = buf;
                self.len = new_len;

                if (self.opts.structured) {
                    self.buffer.srv = try createSRV(self.opts.device, buf.?, new_len);
                } else {
                    self.buffer.srv = null;
                }
            }

            // Map, copy all lists, unmap
            const buf = self.buffer.buf orelse return 0;
            var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = .{};
            const hr = self.opts.context.Map(
                @ptrCast(buf),
                0,
                .WRITE_DISCARD,
                0,
                &mapped,
            );
            if (d3d11.FAILED(hr)) {
                log.warn("Map failed (syncFromArrayLists): hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return error.DirectXFailed;
            }

            const dest: [*]u8 = @ptrCast(mapped.pData orelse {
                self.opts.context.Unmap(@ptrCast(buf), 0);
                return error.DirectXFailed;
            });

            var offset: usize = 0;
            for (lists) |list| {
                if (list.items.len == 0) continue;
                const src = std.mem.sliceAsBytes(list.items);
                @memcpy(dest[offset .. offset + src.len], src);
                offset += src.len;
            }

            self.opts.context.Unmap(@ptrCast(buf), 0);

            return total_len;
        }

        fn createSRV(device: d3d11.ID3D11Device, buf: d3d11.ID3D11Buffer, num_elements: usize) !d3d11.ID3D11ShaderResourceView {
            var srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
                .Format = .UNKNOWN,
                .ViewDimension = .BUFFER,
                .u = .{
                    .Buffer = .{
                        .FirstElement = 0,
                        .NumElements = @intCast(num_elements),
                    },
                },
            };

            var srv: ?d3d11.ID3D11ShaderResourceView = null;
            const hr = device.CreateShaderResourceView(@ptrCast(buf), &srv_desc, &srv);
            if (d3d11.FAILED(hr)) {
                log.err("CreateShaderResourceView (buffer) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return error.DirectXFailed;
            }
            return srv.?;
        }
    };
}
