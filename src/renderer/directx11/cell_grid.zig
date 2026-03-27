// Cell grid instance buffer for the DX11 spike renderer.
//
// Manages a CPU-side array of CellInstance structs and a matching dynamic
// GPU vertex buffer. The render loop fills cells, calls upload() to copy
// to the GPU, then draw() to issue the instanced draw call.

const std = @import("std");
const log = std.log.scoped(.directx11);
const Allocator = std.mem.Allocator;
const com = @import("com.zig");
const d3d11 = @import("d3d11.zig");

const HRESULT = com.HRESULT;

/// Per-cell instance data — must match the HLSL CellInstance and input layout.
pub const CellInstance = extern struct {
    bg_color: [4]f32,
    fg_color: [4]f32,
    glyph_index: u32,
};

pub const CellGrid = struct {
    cols: u32,
    rows: u32,
    cells: []CellInstance,
    instance_buffer: *d3d11.ID3D11Buffer,
    allocator: Allocator,

    pub const InitError = error{
        OutOfMemory,
        BufferCreationFailed,
    };

    pub fn init(allocator: Allocator, device: *d3d11.ID3D11Device, cols: u32, rows: u32) InitError!CellGrid {
        const count = cols * rows;

        // Allocate CPU-side cell array.
        const cells = allocator.alloc(CellInstance, count) catch return InitError.OutOfMemory;
        // Initialize to black with white foreground.
        for (cells) |*cell| {
            cell.* = .{
                .bg_color = .{ 0, 0, 0, 1 },
                .fg_color = .{ 1, 1, 1, 1 },
                .glyph_index = 0,
            };
        }

        // Create dynamic GPU instance buffer.
        const buf_desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = @as(u32, @intCast(count * @sizeOf(CellInstance))),
            .Usage = .DYNAMIC,
            .BindFlags = d3d11.D3D11_BIND_VERTEX_BUFFER,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = 0,
            .StructureByteStride = 0,
        };

        var buffer: ?*d3d11.ID3D11Buffer = null;
        const hr = device.CreateBuffer(&buf_desc, null, &buffer);
        if (com.FAILED(hr) or buffer == null) {
            log.err("CreateBuffer (instance) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            allocator.free(cells);
            return InitError.BufferCreationFailed;
        }

        return CellGrid{
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .instance_buffer = buffer.?,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CellGrid) void {
        _ = self.instance_buffer.Release();
        self.allocator.free(self.cells);
    }

    /// Copy the CPU cell array to the GPU instance buffer.
    pub fn upload(self: *CellGrid, ctx: *d3d11.ID3D11DeviceContext) void {
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = .{ .pData = null, .RowPitch = 0, .DepthPitch = 0 };
        const hr = ctx.Map(
            @ptrCast(self.instance_buffer),
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (com.FAILED(hr) or mapped.pData == null) {
            log.err("Map instance buffer failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return;
        }

        const byte_size = self.cells.len * @sizeOf(CellInstance);
        const dest: [*]u8 = @ptrCast(mapped.pData.?);
        const src: [*]const u8 = @ptrCast(self.cells.ptr);
        @memcpy(dest[0..byte_size], src[0..byte_size]);

        ctx.Unmap(@ptrCast(self.instance_buffer), 0);
    }

    /// Bind the instance buffer and issue the instanced draw call.
    pub fn draw(self: *CellGrid, ctx: *d3d11.ID3D11DeviceContext) void {
        const stride = [_]u32{@sizeOf(CellInstance)};
        const offset = [_]u32{0};
        ctx.IASetVertexBuffers(0, &.{self.instance_buffer}, &stride, &offset);
        ctx.DrawInstanced(6, self.cols * self.rows, 0, 0);
    }

    /// Fill all cells with a single background color.
    pub fn clear(self: *CellGrid, bg: [4]f32) void {
        for (self.cells) |*cell| {
            cell.bg_color = bg;
            cell.fg_color = .{ 1, 1, 1, 1 };
            cell.glyph_index = 0;
        }
    }

    /// Set a single cell by column and row.
    pub fn setCell(self: *CellGrid, col: u32, row: u32, cell: CellInstance) void {
        if (col >= self.cols or row >= self.rows) return;
        self.cells[row * self.cols + col] = cell;
    }

    /// Get a pointer to a single cell.
    pub fn getCell(self: *CellGrid, col: u32, row: u32) ?*CellInstance {
        if (col >= self.cols or row >= self.rows) return null;
        return &self.cells[row * self.cols + col];
    }
};

test "CellInstance size matches HLSL input layout" {
    // bg_color(16) + fg_color(16) + glyph_index(4) = 36 bytes.
    try @import("std").testing.expectEqual(@sizeOf(CellInstance), 36);
}

test "setCell bounds checking" {
    // Can't allocate a real CellGrid without a D3D11 device, but
    // we can verify the bounds logic with a manually constructed grid.
    var cells = [_]CellInstance{.{ .bg_color = .{ 0, 0, 0, 1 }, .fg_color = .{ 1, 1, 1, 1 }, .glyph_index = 0 }} ** 4;
    var grid = CellGrid{
        .cols = 2,
        .rows = 2,
        .cells = &cells,
        .instance_buffer = undefined,
        .allocator = undefined,
    };

    // In-bounds: should set the cell.
    grid.setCell(0, 0, .{ .bg_color = .{ 1, 0, 0, 1 }, .fg_color = .{ 0, 0, 0, 1 }, .glyph_index = 42 });
    try @import("std").testing.expectEqual(grid.cells[0].glyph_index, 42);

    // Out-of-bounds: should be a no-op.
    grid.setCell(5, 5, .{ .bg_color = .{ 1, 0, 0, 1 }, .fg_color = .{ 0, 0, 0, 1 }, .glyph_index = 99 });

    // getCell out-of-bounds returns null.
    try @import("std").testing.expect(grid.getCell(5, 5) == null);
    try @import("std").testing.expect(grid.getCell(0, 0) != null);
}
