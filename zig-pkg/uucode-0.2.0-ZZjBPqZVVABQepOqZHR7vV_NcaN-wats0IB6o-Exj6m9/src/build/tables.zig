const std = @import("std");
const Ucd = @import("Ucd.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const build_config = @import("build_config");
const inlineAssert = config.quirks.inlineAssert;

pub const std_options: std.Options = .{
    .log_level = if (@hasDecl(build_config, "log_level"))
        build_config.log_level
    else
        .info,
};

pub fn main() !void {
    const total_start = try std.time.Instant.now();
    const table_configs: []const config.Table = if (config.is_updating_ucd) &.{updating_ucd} else &build_config.tables;

    var main_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer main_arena.deinit();
    const main_allocator = main_arena.allocator();

    const ucd = try Ucd.init(main_allocator, table_configs);

    var args_iter = try std.process.argsWithAllocator(main_allocator);
    _ = args_iter.skip(); // Skip program name

    // Get output path (only argument now)
    const output_path = args_iter.next() orelse std.debug.panic("No output file arg!", .{});

    std.log.debug("Writing to file: {s}", .{output_path});

    var out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = out_file.writer(&buffer);
    var writer = &file_writer.interface;

    try writer.writeAll(
        \\//! This file is auto-generated. Do not edit.
        \\
        \\const std = @import("std");
        \\const types = @import("types.zig");
        \\const types_x = @import("types.x.zig");
        \\const config = @import("config.zig");
        \\const build_config = @import("build_config");
        \\
        \\
    );

    var table_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer table_arena.deinit();
    const table_allocator = table_arena.allocator();

    comptime var resolved_tables: [table_configs.len]config.Table = undefined;
    inline for (table_configs, 0..) |table_config, i| {
        resolved_tables[i] = table_config.resolve();
    }

    inline for (resolved_tables, 0..) |resolved_table, i| {
        const start = try std.time.Instant.now();

        try writeTableData(
            resolved_table,
            i,
            table_allocator,
            &ucd,
            writer,
        );

        std.log.debug("Arena end capacity: {d}", .{table_arena.queryCapacity()});
        _ = table_arena.reset(.retain_capacity);

        const end = try std.time.Instant.now();
        std.log.debug("`writeTableData` for table_config {d} time: {d}ms", .{ i, end.since(start) / std.time.ns_per_ms });
    }

    try writer.writeAll(
        \\
        \\pub const tables = .{
        \\
    );

    inline for (resolved_tables, 0..) |resolved_table, i| {
        try writeTable(
            resolved_table,
            i,
            table_allocator,
            writer,
        );
    }

    try writer.writeAll(
        \\
        \\};
        \\
    );

    try writer.flush();

    std.log.debug("Main arena end capacity: {d}", .{main_arena.queryCapacity()});

    const total_end = try std.time.Instant.now();
    std.log.debug("Total time: {d}ms", .{total_end.since(total_start) / std.time.ns_per_ms});

    if (config.is_updating_ucd) {
        @panic("Updating Ucd -- tables not configured to actully run. flip `is_updating_ucd` to false and run again");
    }
}

const updating_ucd_fields = brk: {
    const d = config.default;
    const max_cp: u21 = config.max_code_point;

    @setEvalBranchQuota(5_000);
    var fields: [d.fields.len]config.Field = undefined;

    for (d.fields, 0..) |f, i| {
        switch (f.kind()) {
            .basic => {
                fields[i] = f;
            },
            .optional => {
                fields[i] = f.override(.{
                    .min_value = std.math.minInt(isize),
                    .max_value = std.math.maxInt(isize) - 1,
                });
            },
            .shift, .@"union" => {
                fields[i] = f.override(.{
                    .shift_low = -@as(isize, max_cp),
                    .shift_high = max_cp,
                });
            },
            .slice => {
                fields[i] = f.override(.{
                    .shift_low = -@as(isize, max_cp),
                    .shift_high = max_cp,
                    .max_len = if (f.max_len > 0)
                        f.max_len * 3 + 100
                    else
                        0,
                    .max_offset = f.max_offset * 3 + 1000,
                    .embedded_len = 0,
                });
            },
        }
    }

    break :brk fields;
};

const updating_ucd = config.Table{
    .fields = &updating_ucd_fields,
};

fn hashData(comptime Data: type, hasher: anytype, data: Data) void {
    inline for (@typeInfo(Data).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .@"struct" and @hasDecl(field.type, "autoHash")) {
            @field(data, field.name).autoHash(hasher);
        } else {
            std.hash.autoHash(hasher, @field(data, field.name));
        }
    }
}

fn eqlData(comptime Data: type, a: Data, b: Data) bool {
    inline for (@typeInfo(Data).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .@"struct" and @hasDecl(field.type, "eql")) {
            if (!@field(a, field.name).eql(@field(b, field.name))) {
                return false;
            }
        } else {
            if (!std.meta.eql(@field(a, field.name), @field(b, field.name))) {
                return false;
            }
        }
    }
    return true;
}

fn DataMap(comptime Data: type) type {
    return std.HashMapUnmanaged(Data, u32, struct {
        pub fn hash(self: @This(), data: Data) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(128572459);
            hashData(Data, &hasher, data);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: Data, b: Data) bool {
            _ = self;
            return eqlData(Data, a, b);
        }
    }, std.hash_map.default_max_load_percentage);
}

const block_size = 256;

fn Block(comptime T: type) type {
    inlineAssert(T == u32 or @typeInfo(T) == .@"struct");
    return [block_size]T;
}

fn BlockMap(comptime B: type) type {
    const T = @typeInfo(B).array.child;
    return std.HashMapUnmanaged(B, u32, struct {
        pub fn hash(self: @This(), block: B) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(915296157);
            if (@typeInfo(T) == .@"struct") {
                for (block) |item| {
                    hashData(T, &hasher, item);
                }
            } else {
                std.hash.autoHash(&hasher, block);
            }
            return hasher.final();
        }

        pub fn eql(self: @This(), a: B, b: B) bool {
            _ = self;
            if (@typeInfo(T) == .@"struct") {
                for (a, b) |a_item, b_item| {
                    if (!eqlData(T, a_item, b_item)) {
                        return false;
                    }
                }

                return true;
            } else {
                return std.mem.eql(T, &a, &b);
            }
        }
    }, std.hash_map.default_max_load_percentage);
}

fn TableAllData(comptime c: config.Table) type {
    @setEvalBranchQuota(20_000);
    var x_fields_len: usize = 0;
    var fields_len_bound: usize = c.fields.len;
    for (c.extensions) |x| {
        x_fields_len += x.fields.len;
        fields_len_bound += x.fields.len;
        fields_len_bound += x.inputs.len;
    }
    var x_fields: [x_fields_len]config.Field = undefined;
    var x_i: usize = 0;

    // Union extension fields:
    for (c.extensions) |x| {
        for (x.fields) |xf| {
            for (x_fields[0..x_i]) |existing| {
                if (std.mem.eql(u8, existing.name, xf.name)) {
                    @compileError("Extension field '" ++ xf.name ++ "' already exists in table");
                }
            }

            x_fields[x_i] = xf;
            x_i += 1;
        }
    }

    var fields: [fields_len_bound]std.builtin.Type.StructField = undefined;
    var i: usize = 0;

    // Add Data fields:
    for (c.fields, 0..) |cf, c_i| {
        for (c.fields[0..c_i]) |existing| {
            if (std.mem.eql(u8, existing.name, cf.name)) {
                @compileError("Field '" ++ cf.name ++ "' already exists in table");
            }
        }

        // If a field isn't in `default` it's an extension field, which should
        // be in x_fields.
        if (!config.default.hasField(cf.name)) {
            const x_field: ?config.Field = for (x_fields) |xf| {
                if (std.mem.eql(u8, xf.name, cf.name)) break xf;
            } else null;

            if (x_field) |xf| {
                if (!xf.eql(cf)) {
                    @compileError("Table field '" ++ cf.name ++ "' does not match the field in the extension");
                }
            } else {
                @compileError("Table field '" ++ cf.name ++ "' not found in any of the table's extensions");
            }
        }

        const F = types.Field(cf, c.packing);
        fields[i] = .{
            .name = cf.name,
            .type = F,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(F),
        };
        i += 1;
    }

    // Add extension inputs:
    for (c.extensions) |x| {
        loop_inputs: for (x.inputs) |input| {
            for (fields[0..i]) |existing| {
                if (std.mem.eql(u8, existing.name, input)) {
                    continue :loop_inputs;
                }
            }

            var cf: config.Field = undefined;

            if (config.default.hasField(input)) {
                cf = config.default.field(input);
            } else {
                // If a field isn't in `default` it's an extension field, which should
                // be in x_fields.
                cf = for (x_fields) |xf| {
                    if (std.mem.eql(u8, xf.name, input)) break xf;
                } else {
                    @compileError("Extension field for input '" ++ input ++ "' not found in any of the table's extensions");
                };
            }

            const F = types.Field(cf, .unpacked);
            fields[i] = .{
                .name = input,
                .type = F,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(F),
            };
            i += 1;
        }
    }

    const all_fields = fields[0..i];

    // We sanity check here that at least one field from every extension is
    // present in AllData, otherwise it's a configuration error, and we want to
    // avoid running an extension that won't be used.
    loop_extensions: for (c.extensions) |x| {
        for (x.fields) |xf| {
            for (all_fields) |f| {
                if (std.mem.eql(u8, xf.name, f.name)) {
                    continue :loop_extensions;
                }
            }
        }

        if (x.fields.len > 0) {
            @compileError("Extension with field '" ++ x.fields[0].name ++ "' has no fields present in table or other extension inputs");
        } else {
            @compileError("Extension has no fields");
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = all_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

fn TableTracking(comptime Struct: type) type {
    const fields = @typeInfo(Struct).@"struct".fields;
    var tracking_fields: [fields.len]std.builtin.Type.StructField = undefined;
    var i: usize = 0;

    for (@typeInfo(Struct).@"struct".fields) |f| {
        switch (@typeInfo(f.type)) {
            .@"struct", .@"union" => {
                if (@hasDecl(f.type, "Tracking") and f.type.Tracking != void) {
                    const T = @field(f.type, "Tracking");
                    tracking_fields[i] = .{
                        .name = f.name,
                        .type = T,
                        .default_value_ptr = null, // TODO: can we set this?
                        .is_comptime = false,
                        .alignment = @alignOf(T),
                    };
                    i += 1;
                }
            },
            .optional => |optional| {
                if (config.isPackable(optional.child)) {
                    const T = types.OptionalTracking(f.type);
                    tracking_fields[i] = .{
                        .name = f.name,
                        .type = T,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(T),
                    };
                    i += 1;
                }
            },
            else => {},
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = tracking_fields[0..i],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

fn maybePackedInit(
    comptime field: []const u8,
    data: anytype,
    tracking: anytype,
    d: anytype,
) void {
    const Field = @FieldType(@typeInfo(@TypeOf(data)).pointer.child, field);
    if (@typeInfo(Field) == .@"struct" and @hasDecl(Field, "init")) {
        @field(data, field) = .init(d);
    } else {
        @field(data, field) = d;
    }
    const Tracking = @typeInfo(@TypeOf(tracking)).pointer.child;
    if (@hasField(Tracking, field)) {
        @field(tracking, field).track(d);
    }
}

fn tablePrefix(
    comptime table_config: config.Table,
    table_index: usize,
    allocator: std.mem.Allocator,
) !struct { []const u8, []const u8 } {
    const prefix = if (table_config.name) |name|
        try std.fmt.allocPrint(allocator, "table_{s}", .{name})
    else
        try std.fmt.allocPrint(allocator, "table_{d}", .{table_index});

    const TypePrefix = if (table_config.name) |name|
        try std.fmt.allocPrint(allocator, "Table_{s}", .{name})
    else
        try std.fmt.allocPrint(allocator, "Table_{d}", .{table_index});

    return .{ prefix, TypePrefix };
}

pub fn writeTableData(
    comptime table_config: config.Table,
    table_index: usize,
    allocator: std.mem.Allocator,
    ucd: *const Ucd,
    writer: *std.Io.Writer,
) !void {
    const Data = types.Data(table_config);
    const AllData = TableAllData(table_config);
    const Backing = types.StructFromDecls(AllData, "MutableBackingBuffer");
    const Tracking = TableTracking(AllData);

    var backing = blk: {
        var b: Backing = undefined;
        inline for (@typeInfo(Backing).@"struct".fields) |field| {
            comptime var c: config.Field = undefined;
            if (comptime table_config.hasField(field.name)) {
                c = table_config.field(field.name);
            } else if (comptime config.default.hasField(field.name)) {
                c = config.default.field(field.name);
            } else {
                c = x_blk: for (table_config.extensions) |x| {
                    for (x.fields) |f| {
                        if (std.mem.eql(u8, f.name, field.name)) {
                            break :x_blk f;
                        }
                    }
                } else unreachable;
            }

            const T = @typeInfo(field.type).pointer.child;
            @field(b, field.name) = try allocator.alloc(T, c.max_offset);
        }

        break :blk b;
    };

    var tracking = blk: {
        var t: Tracking = undefined;
        inline for (@typeInfo(Tracking).@"struct".fields) |field| {
            @field(t, field.name) = .{};
        }
        break :blk t;
    };

    const stages = table_config.stages;
    const num_stages: u2 = if (stages == .three) 3 else 2;

    const Stage2Elem = if (stages == .three)
        u32
    else
        Data;

    const B = Block(Stage2Elem);

    var data_map: DataMap(Data) = .empty;
    var stage3: std.ArrayListUnmanaged(Data) = .empty;
    var block_map: BlockMap(B) = .empty;
    var stage2: std.ArrayListUnmanaged(Stage2Elem) = .empty;
    var stage1: std.ArrayListUnmanaged(u32) = .empty;

    var block: B = undefined;
    var block_len: usize = 0;

    const build_data_start = try std.time.Instant.now();
    var get_data_time: u64 = 0;

    for (0..config.max_code_point + 1) |cp_usize| {
        const get_data_start = try std.time.Instant.now();
        const cp: u21 = @intCast(cp_usize);

        const get_data_end = try std.time.Instant.now();
        get_data_time += get_data_end.since(get_data_start);

        var a: AllData = undefined;

        if (comptime Ucd.needsSection(table_config, .unicode_data)) {
            const unicode_data = &ucd.unicode_data[cp];

            if (@hasField(AllData, "name")) {
                a.name = try .init(
                    allocator,
                    backing.name,
                    &tracking.name,
                    unicode_data.name,
                );
            }
            if (@hasField(AllData, "general_category")) {
                a.general_category = unicode_data.general_category;
            }
            if (@hasField(AllData, "canonical_combining_class")) {
                a.canonical_combining_class = unicode_data.canonical_combining_class;
            }
            if (@hasField(AllData, "decomposition_type")) {
                a.decomposition_type = unicode_data.decomposition_type;
            }
            if (@hasField(AllData, "decomposition_mapping")) {
                a.decomposition_mapping = try .initFor(
                    allocator,
                    backing.decomposition_mapping,
                    &tracking.decomposition_mapping,
                    unicode_data.decomposition_mapping,
                    cp,
                );
            }
            if (@hasField(AllData, "numeric_type")) {
                a.numeric_type = unicode_data.numeric_type;
            }
            if (@hasField(AllData, "numeric_value_decimal")) {
                maybePackedInit(
                    "numeric_value_decimal",
                    &a,
                    &tracking,
                    unicode_data.numeric_value_decimal,
                );
            }
            if (@hasField(AllData, "numeric_value_digit")) {
                maybePackedInit(
                    "numeric_value_digit",
                    &a,
                    &tracking,
                    unicode_data.numeric_value_digit,
                );
            }
            if (@hasField(AllData, "numeric_value_numeric")) {
                a.numeric_value_numeric = try .init(
                    allocator,
                    backing.numeric_value_numeric,
                    &tracking.numeric_value_numeric,
                    unicode_data.numeric_value_numeric,
                );
            }
            if (@hasField(AllData, "is_bidi_mirrored")) {
                a.is_bidi_mirrored = unicode_data.is_bidi_mirrored;
            }
            if (@hasField(AllData, "unicode_1_name")) {
                a.unicode_1_name = try .init(
                    allocator,
                    backing.unicode_1_name,
                    &tracking.unicode_1_name,
                    unicode_data.unicode_1_name,
                );
            }
            if (@hasField(AllData, "simple_uppercase_mapping")) {
                types.fieldInit(
                    "simple_uppercase_mapping",
                    cp,
                    &a,
                    &tracking,
                    unicode_data.simple_uppercase_mapping,
                );
            }
            if (@hasField(AllData, "simple_lowercase_mapping")) {
                types.fieldInit(
                    "simple_lowercase_mapping",
                    cp,
                    &a,
                    &tracking,
                    unicode_data.simple_lowercase_mapping,
                );
            }
            if (@hasField(AllData, "simple_titlecase_mapping")) {
                types.fieldInit(
                    "simple_titlecase_mapping",
                    cp,
                    &a,
                    &tracking,
                    unicode_data.simple_titlecase_mapping,
                );
            }
        }

        // BidiClass
        if (@hasField(AllData, "bidi_class")) {
            comptime inlineAssert(Ucd.needsSection(table_config, .derived_bidi_class));
            const derived_bidi_class = ucd.derived_bidi_class[cp];
            inlineAssert((comptime !Ucd.needsSection(table_config, .unicode_data)) or
                (ucd.unicode_data[cp].bidi_class == null or ucd.unicode_data[cp].bidi_class.? == derived_bidi_class));
            a.bidi_class = derived_bidi_class;
        }

        if (comptime Ucd.needsSection(table_config, .case_folding)) {
            const case_folding = &ucd.case_folding[cp];

            if (@hasField(AllData, "case_folding_simple")) {
                const d =
                    case_folding.case_folding_simple_only orelse
                    case_folding.case_folding_common_only orelse

                    // This would seem not to be necessary based on the heading
                    // of CaseFolding.txt, but U+0130 has only an F and T
                    // mapping and no S. The T mapping is the same as the
                    // simple_lowercase_mapping so we use that here.
                    case_folding.case_folding_turkish_only orelse
                    cp;
                types.fieldInit("case_folding_simple", cp, &a, &tracking, d);
            }
            if (@hasField(AllData, "case_folding_full")) {
                if (case_folding.case_folding_full_only.len > 0) {
                    a.case_folding_full = try .initFor(
                        allocator,
                        backing.case_folding_full,
                        &tracking.case_folding_full,
                        case_folding.case_folding_full_only,
                        cp,
                    );
                } else {
                    a.case_folding_full = try .initFor(
                        allocator,
                        backing.case_folding_full,
                        &tracking.case_folding_full,
                        &.{case_folding.case_folding_common_only orelse cp},
                        cp,
                    );
                }
            }
            if (@hasField(AllData, "case_folding_turkish_only")) {
                if (case_folding.case_folding_turkish_only) |t| {
                    a.case_folding_turkish_only = try .initFor(
                        allocator,
                        backing.case_folding_turkish_only,
                        &tracking.case_folding_turkish_only,
                        &.{t},
                        cp,
                    );
                } else {
                    a.case_folding_turkish_only = .empty;
                }
            }
            if (@hasField(AllData, "case_folding_common_only")) {
                if (case_folding.case_folding_common_only) |c| {
                    a.case_folding_common_only = try .initFor(
                        allocator,
                        backing.case_folding_common_only,
                        &tracking.case_folding_common_only,
                        &.{c},
                        cp,
                    );
                } else {
                    a.case_folding_common_only = .empty;
                }
            }
            if (@hasField(AllData, "case_folding_simple_only")) {
                if (case_folding.case_folding_simple_only) |s| {
                    a.case_folding_simple_only = try .initFor(
                        allocator,
                        backing.case_folding_simple_only,
                        &tracking.case_folding_simple_only,
                        &.{s},
                        cp,
                    );
                } else {
                    a.case_folding_simple_only = .empty;
                }
            }
            if (@hasField(AllData, "case_folding_full_only")) {
                a.case_folding_full_only = try .initFor(
                    allocator,
                    backing.case_folding_full_only,
                    &tracking.case_folding_full_only,
                    case_folding.case_folding_full_only,
                    cp,
                );
            }
        }

        if (comptime Ucd.needsSection(table_config, .special_casing)) {
            const special_casing = &ucd.special_casing[cp];

            if (@hasField(AllData, "has_special_casing")) {
                a.has_special_casing = special_casing.has_special_casing;
            }
            if (@hasField(AllData, "special_lowercase_mapping")) {
                a.special_lowercase_mapping = try .initFor(
                    allocator,
                    backing.special_lowercase_mapping,
                    &tracking.special_lowercase_mapping,
                    special_casing.special_lowercase_mapping,
                    cp,
                );
            }
            if (@hasField(AllData, "special_titlecase_mapping")) {
                a.special_titlecase_mapping = try .initFor(
                    allocator,
                    backing.special_titlecase_mapping,
                    &tracking.special_titlecase_mapping,
                    special_casing.special_titlecase_mapping,
                    cp,
                );
            }
            if (@hasField(AllData, "special_uppercase_mapping")) {
                a.special_uppercase_mapping = try .initFor(
                    allocator,
                    backing.special_uppercase_mapping,
                    &tracking.special_uppercase_mapping,
                    special_casing.special_uppercase_mapping,
                    cp,
                );
            }
            if (@hasField(AllData, "special_casing_condition")) {
                a.special_casing_condition = try .init(
                    allocator,
                    backing.special_casing_condition,
                    &tracking.special_casing_condition,
                    special_casing.special_casing_condition,
                );
            }
        }

        // Case mappings
        if (@hasField(AllData, "lowercase_mapping") or
            @hasField(AllData, "titlecase_mapping") or
            @hasField(AllData, "uppercase_mapping"))
        {
            const unicode_data = &ucd.unicode_data[cp];
            const special_casing = &ucd.special_casing[cp];

            if (@hasField(AllData, "lowercase_mapping")) {
                const use_special = special_casing.has_special_casing and
                    special_casing.special_casing_condition.len == 0;

                if (use_special) {
                    a.lowercase_mapping = try .initFor(
                        allocator,
                        backing.lowercase_mapping,
                        &tracking.lowercase_mapping,
                        special_casing.special_lowercase_mapping,
                        cp,
                    );
                } else {
                    a.lowercase_mapping = try .initFor(
                        allocator,
                        backing.lowercase_mapping,
                        &tracking.lowercase_mapping,
                        &.{unicode_data.simple_lowercase_mapping},
                        cp,
                    );
                }
            }

            if (@hasField(AllData, "titlecase_mapping")) {
                const use_special = special_casing.has_special_casing and
                    special_casing.special_casing_condition.len == 0;

                if (use_special) {
                    a.titlecase_mapping = try .initFor(
                        allocator,
                        backing.titlecase_mapping,
                        &tracking.titlecase_mapping,
                        special_casing.special_titlecase_mapping,
                        cp,
                    );
                } else {
                    a.titlecase_mapping = try .initFor(
                        allocator,
                        backing.titlecase_mapping,
                        &tracking.titlecase_mapping,
                        &.{unicode_data.simple_titlecase_mapping},
                        cp,
                    );
                }
            }

            if (@hasField(AllData, "uppercase_mapping")) {
                const use_special = special_casing.has_special_casing and
                    special_casing.special_casing_condition.len == 0;

                if (use_special) {
                    a.uppercase_mapping = try .initFor(
                        allocator,
                        backing.uppercase_mapping,
                        &tracking.uppercase_mapping,
                        special_casing.special_uppercase_mapping,
                        cp,
                    );
                } else {
                    a.uppercase_mapping = try .initFor(
                        allocator,
                        backing.uppercase_mapping,
                        &tracking.uppercase_mapping,
                        &.{unicode_data.simple_uppercase_mapping},
                        cp,
                    );
                }
            }
        }

        if (comptime Ucd.needsSection(table_config, .derived_core_properties)) {
            const derived_core_properties = &ucd.derived_core_properties[cp];

            if (@hasField(AllData, "is_math")) {
                a.is_math = derived_core_properties.is_math;
            }
            if (@hasField(AllData, "is_alphabetic")) {
                a.is_alphabetic = derived_core_properties.is_alphabetic;
            }
            if (@hasField(AllData, "is_lowercase")) {
                a.is_lowercase = derived_core_properties.is_lowercase;
            }
            if (@hasField(AllData, "is_uppercase")) {
                a.is_uppercase = derived_core_properties.is_uppercase;
            }
            if (@hasField(AllData, "is_cased")) {
                a.is_cased = derived_core_properties.is_cased;
            }
            if (@hasField(AllData, "is_case_ignorable")) {
                a.is_case_ignorable = derived_core_properties.is_case_ignorable;
            }
            if (@hasField(AllData, "changes_when_lowercased")) {
                a.changes_when_lowercased = derived_core_properties.changes_when_lowercased;
            }
            if (@hasField(AllData, "changes_when_uppercased")) {
                a.changes_when_uppercased = derived_core_properties.changes_when_uppercased;
            }
            if (@hasField(AllData, "changes_when_titlecased")) {
                a.changes_when_titlecased = derived_core_properties.changes_when_titlecased;
            }
            if (@hasField(AllData, "changes_when_casefolded")) {
                a.changes_when_casefolded = derived_core_properties.changes_when_casefolded;
            }
            if (@hasField(AllData, "changes_when_casemapped")) {
                a.changes_when_casemapped = derived_core_properties.changes_when_casemapped;
            }
            if (@hasField(AllData, "is_id_start")) {
                a.is_id_start = derived_core_properties.is_id_start;
            }
            if (@hasField(AllData, "is_id_continue")) {
                a.is_id_continue = derived_core_properties.is_id_continue;
            }
            if (@hasField(AllData, "is_xid_start")) {
                a.is_xid_start = derived_core_properties.is_xid_start;
            }
            if (@hasField(AllData, "is_xid_continue")) {
                a.is_xid_continue = derived_core_properties.is_xid_continue;
            }
            if (@hasField(AllData, "is_default_ignorable")) {
                a.is_default_ignorable = derived_core_properties.is_default_ignorable;
            }
            if (@hasField(AllData, "is_grapheme_extend")) {
                a.is_grapheme_extend = derived_core_properties.is_grapheme_extend;
            }
            if (@hasField(AllData, "is_grapheme_base")) {
                a.is_grapheme_base = derived_core_properties.is_grapheme_base;
            }
            if (@hasField(AllData, "is_grapheme_link")) {
                a.is_grapheme_link = derived_core_properties.is_grapheme_link;
            }
            if (@hasField(AllData, "indic_conjunct_break")) {
                a.indic_conjunct_break = derived_core_properties.indic_conjunct_break;
            }
        }

        // EastAsianWidth
        if (@hasField(AllData, "east_asian_width")) {
            const east_asian_width = ucd.east_asian_width[cp];
            a.east_asian_width = east_asian_width;
        }

        // Block
        if (@hasField(AllData, "block")) {
            const block_value = ucd.blocks[cp];
            a.block = block_value;
        }

        // Script
        if (@hasField(AllData, "script")) {
            const script_value = ucd.scripts[cp];
            a.script = script_value;
        }

        // Joining Type
        if (@hasField(AllData, "joining_type")) {
            const jt_value = ucd.joining_types[cp];
            a.joining_type = jt_value;
        }

        // Joining Group
        if (@hasField(AllData, "joining_group")) {
            const jg_value = ucd.joining_groups[cp];
            a.joining_group = jg_value;
        }

        // Composition Exclusions
        if (@hasField(AllData, "is_composition_exclusion")) {
            const exclusion = ucd.is_composition_exclusions[cp];
            a.is_composition_exclusion = exclusion;
        }

        // Indic Positional Category
        if (@hasField(AllData, "indic_positional_category")) {
            const ipc = ucd.indic_positional_category[cp];
            a.indic_positional_category = ipc;
        }

        // Indic Syllabic Category
        if (@hasField(AllData, "indic_syllabic_category")) {
            const ipc = ucd.indic_syllabic_category[cp];
            a.indic_syllabic_category = ipc;
        }

        // OriginalGraphemeBreak
        if (@hasField(AllData, "original_grapheme_break")) {
            const original_grapheme_break = ucd.original_grapheme_break[cp];
            a.original_grapheme_break = original_grapheme_break;
        }

        // EmojiData
        if (comptime Ucd.needsSection(table_config, .emoji_data)) {
            const emoji_data = &ucd.emoji_data[cp];

            if (@hasField(AllData, "is_emoji")) {
                a.is_emoji = emoji_data.is_emoji;
            }
            if (@hasField(AllData, "is_emoji_presentation")) {
                a.is_emoji_presentation = emoji_data.is_emoji_presentation;
            }
            if (@hasField(AllData, "is_emoji_modifier")) {
                a.is_emoji_modifier = emoji_data.is_emoji_modifier;
            }
            if (@hasField(AllData, "is_emoji_modifier_base")) {
                a.is_emoji_modifier_base = emoji_data.is_emoji_modifier_base;
            }
            if (@hasField(AllData, "is_emoji_component")) {
                a.is_emoji_component = emoji_data.is_emoji_component;
            }
            if (@hasField(AllData, "is_extended_pictographic")) {
                a.is_extended_pictographic = emoji_data.is_extended_pictographic;
            }
        }

        if (comptime Ucd.needsSection(table_config, .emoji_vs)) {
            const emoji_vs = &ucd.emoji_vs[cp];

            if (@hasField(AllData, "is_emoji_vs_base")) {
                inlineAssert(emoji_vs.is_text == emoji_vs.is_emoji);
                a.is_emoji_vs_base = emoji_vs.is_text;
            }
            if (@hasField(AllData, "is_emoji_vs_text")) {
                a.is_emoji_vs_text = emoji_vs.is_text;
            }
            if (@hasField(AllData, "is_emoji_vs_emoji")) {
                a.is_emoji_vs_emoji = emoji_vs.is_emoji;
            }
        }

        if (@hasField(AllData, "bidi_paired_bracket")) {
            const bidi_paired_bracket = ucd.bidi_paired_bracket[cp];
            types.fieldInit(
                "bidi_paired_bracket",
                cp,
                &a,
                &tracking,
                bidi_paired_bracket,
            );
        }

        // GraphemeBreak
        if (@hasField(AllData, "grapheme_break")) {
            const emoji_data = &ucd.emoji_data[cp];
            const original_grapheme_break = ucd.original_grapheme_break[cp];
            const derived_core_properties = &ucd.derived_core_properties[cp];

            if (emoji_data.is_emoji_modifier) {
                inlineAssert(original_grapheme_break == .extend);
                inlineAssert(!emoji_data.is_extended_pictographic and
                    emoji_data.is_emoji_component);
                a.grapheme_break = .emoji_modifier;
            } else if (emoji_data.is_emoji_modifier_base) {
                inlineAssert(original_grapheme_break == .other);
                inlineAssert(emoji_data.is_extended_pictographic);
                a.grapheme_break = .emoji_modifier_base;
            } else if (emoji_data.is_extended_pictographic) {
                inlineAssert(original_grapheme_break == .other);
                a.grapheme_break = .extended_pictographic;
            } else {
                switch (derived_core_properties.indic_conjunct_break) {
                    .none => {
                        @setEvalBranchQuota(50_000);
                        a.grapheme_break = switch (original_grapheme_break) {
                            .extend => blk: {
                                if (cp == config.zero_width_non_joiner) {
                                    // `zwnj` is the only grapheme break
                                    // `extend` that is `none` for Indic
                                    // conjunct break as opposed to ICB
                                    // `extend` or `linker`.
                                    break :blk .zwnj;
                                } else {
                                    std.log.err(
                                        "Found an `extend` grapheme break that is Indic conjunct break `none` (and not zwnj): {x}",
                                        .{cp},
                                    );
                                    unreachable;
                                }
                            },
                            inline else => |o| comptime std.meta.stringToEnum(
                                types.GraphemeBreak,
                                @tagName(o),
                            ) orelse unreachable,
                        };
                    },
                    .extend => {
                        if (cp == config.zero_width_joiner) {
                            inlineAssert(original_grapheme_break == .zwj);
                            a.grapheme_break = .zwj;
                        } else {
                            inlineAssert(original_grapheme_break == .extend);
                            a.grapheme_break = .indic_conjunct_break_extend;
                        }
                    },
                    .linker => {
                        inlineAssert(original_grapheme_break == .extend);
                        a.grapheme_break = .indic_conjunct_break_linker;
                    },
                    .consonant => {
                        inlineAssert(original_grapheme_break == .other);
                        a.grapheme_break = .indic_conjunct_break_consonant;
                    },
                }
            }
        }

        inline for (table_config.extensions) |extension| {
            try extension.compute(allocator, cp, &a, &backing, &tracking);
        }

        var d: Data = undefined;

        inline for (@typeInfo(Data).@"struct".fields) |f| {
            @field(d, f.name) = @field(a, f.name);
        }

        if (stages == .three) {
            const gop = try data_map.getOrPut(allocator, d);
            var data_index: u32 = undefined;
            if (gop.found_existing) {
                data_index = gop.value_ptr.*;
            } else {
                data_index = @intCast(stage3.items.len);
                gop.value_ptr.* = data_index;
                try stage3.append(allocator, d);
            }

            block[block_len] = data_index;
            block_len += 1;
        } else {
            block[block_len] = d;
            block_len += 1;
        }

        if (block_len == block_size) {
            const gop_block = try block_map.getOrPut(allocator, block);
            var block_offset: u32 = undefined;
            if (gop_block.found_existing) {
                block_offset = gop_block.value_ptr.*;
            } else {
                block_offset = @intCast(stage2.items.len);
                gop_block.value_ptr.* = block_offset;
                try stage2.appendSlice(allocator, &block);
            }

            try stage1.append(allocator, block_offset);
            block_len = 0;
        }
    }

    inlineAssert(block_len == 0);

    std.log.debug("Getting data time: {d}ms", .{get_data_time / std.time.ns_per_ms});
    std.log.debug("Table stage 1 len: {d}", .{stage1.items.len});
    std.log.debug("Table stage 2 len: {d} (u{d})", .{ stage2.items.len, 1 + std.math.log2(stage2.items.len) });
    if (stages == .three) {
        std.log.debug("Table stage 3 len: {d} (u{d})", .{ stage3.items.len, 1 + std.math.log2(stage3.items.len) });
    }

    const build_data_end = try std.time.Instant.now();
    std.log.debug("Building data time: {d}ms", .{build_data_end.since(build_data_start) / std.time.ns_per_ms});

    const prefix, const TypePrefix = try tablePrefix(table_config, table_index, allocator);

    try writer.print(
        \\const {s}_config = config.Table{{
        \\
    , .{prefix});

    try writer.writeAll("    .packing = ");
    try table_config.packing.write(writer);

    try writer.writeAll(
        \\,
        \\    .fields = &.{
        \\
    );

    var all_fields_okay = true;

    inline for (table_config.fields) |f| {
        const r = f.runtime();

        if (@hasField(Tracking, f.name)) {
            const t = @field(tracking, f.name);
            if (config.is_updating_ucd) {
                const min_config = t.minBitsConfig(r);
                if (!config.default.field(f.name).runtime().eql(min_config)) {
                    std.debug.print("Unequal!\n", .{});
                    var buffer: [4096]u8 = undefined;
                    var stderr_writer = std.fs.File.stderr().writer(&buffer);
                    var w = &stderr_writer.interface;
                    try w.writeAll(
                        \\
                        \\Update default config in `config.zig` with the correct field config:
                        \\
                    );
                    try min_config.write(w);
                    try w.flush();
                }
            } else {
                if (!r.compareActual(t.actualConfig(r))) {
                    all_fields_okay = false;
                }
            }
        }

        try r.write(writer);
    }

    if (!all_fields_okay) {
        @panic("Table config doesn't match actual. See above for details");
    }

    try writer.print(
        \\    }},
        \\}};
        \\
        \\const {s}_Data = types.Data({s}_config);
        \\const {s}_Backing = types.Backing({s}_Data);
        \\const {s}_Stage1 = u{};
        \\
    ,
        .{
            TypePrefix,
            prefix,
            TypePrefix,
            TypePrefix,
            TypePrefix,
            1 + std.math.log2(stage2.items.len),
        },
    );

    if (stages == .three) {
        try writer.print(
            \\const {s}_Stage2 = u{};
            \\
        ,
            .{
                TypePrefix,
                1 + std.math.log2(stage3.items.len),
            },
        );
    }

    inline for (@typeInfo(Backing).@"struct".fields) |field| {
        if (!@hasField(Data, field.name)) continue;

        const T = @typeInfo(field.type).pointer.child;

        try writer.print("const {s}_backing_{s}: []const {s} = ", .{
            prefix,
            field.name,
            @typeName(T),
        });

        const b = @field(backing, field.name);
        const t = @field(tracking, field.name);

        if (T == u8) {
            try writer.print("\"{s}\";\n", .{b[0..t.max_offset]});
        } else {
            try writer.writeAll("&.{");

            for (b[0..t.max_offset]) |item| {
                try writer.print("{},", .{item});
            }

            try writer.writeAll(
                \\};
                \\
            );
        }
    }

    try writer.print(
        \\
        \\const {s}_backing = {s}_Backing{{
        \\
    ,
        .{ prefix, TypePrefix },
    );

    inline for (@typeInfo(Backing).@"struct".fields) |field| {
        if (!@hasField(Data, field.name)) continue;

        try writer.print(
            \\    .{s} = {s}_backing_{s},
            \\
        , .{
            field.name,
            prefix,
            field.name,
        });
    }

    try writer.print(
        \\}};
        \\
        \\const {s}_stage1: [{d}]{s}_Stage1 align(std.atomic.cache_line) = .{{
        \\
    ,
        .{ prefix, stage1.items.len, TypePrefix },
    );

    for (stage1.items) |item| {
        try writer.print("{},", .{item});
    }

    if (stages == .three) {
        try writer.print(
            \\
            \\}};
            \\
            \\const {s}_stage2: [{d}]{s}_Stage2 align(std.atomic.cache_line) = .{{
            \\
        ,
            .{ prefix, stage2.items.len, TypePrefix },
        );

        for (stage2.items) |item| {
            try writer.print("{},", .{item});
        }
    }

    const data_items = if (stages == .three) stage3.items else stage2.items;

    try writer.writeAll(
        \\
        \\};
        \\
        \\
    );

    try writer.print(
        "const {s}_stage{d}: [{d}]{s}_Data align(@max(std.atomic.cache_line, @alignOf({s}_Data))) = ",
        .{ prefix, num_stages, data_items.len, TypePrefix, TypePrefix },
    );

    try types.writeDataItems(Data, writer, data_items);

    try writer.writeAll(
        \\
        \\
    );
}

fn writeTable(
    comptime table_config: config.Table,
    table_index: usize,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    if (table_config.name) |name| {
        try writer.print("    .{s} = ", .{name});
    } else {
        try writer.print("    .@\"{d}\" = ", .{table_index});
    }

    const prefix, const TypePrefix = try tablePrefix(table_config, table_index, allocator);

    if (table_config.stages == .three) {
        try writer.print(
            \\types.Table3({s}_Stage1, {s}_Stage2, {s}_Data, {s}_Backing){{
            \\        .stage1 = &{s}_stage1,
            \\        .stage2 = &{s}_stage2,
            \\        .stage3 = &{s}_stage3,
            \\        .backing = &{s}_backing,
            \\    }},
            \\
        , .{
            TypePrefix,
            TypePrefix,
            TypePrefix,
            TypePrefix,
            prefix,
            prefix,
            prefix,
            prefix,
        });
    } else {
        try writer.print(
            \\types.Table2({s}_Stage1, {s}_Data, {s}_Backing){{
            \\        .stage1 = &{s}_stage1,
            \\        .stage2 = &{s}_stage2,
            \\        .backing = &{s}_backing,
            \\    }},
            \\
        , .{
            TypePrefix,
            TypePrefix,
            TypePrefix,
            prefix,
            prefix,
            prefix,
        });
    }
}
