//! Checks that a change to libghostty-vt doesn't break programs built
//! against an earlier version of the library.
//!
//! The check compares a freshly built library to files committed next to
//! this one, called goldens:
//!
//!   - `<target>.json` is the type manifest for one target, as returned by
//!     `ghostty_type_json`. It records every public type with its size,
//!     field offsets and enum values. Fields that change on every build,
//!     such as the commit, are left out.
//!   - `symbols.txt` is the sorted list of public functions. It is the same
//!     on every target.
//!
//! A change passes if it only adds to the ABI. These additions are allowed:
//!
//!   - a new type
//!   - a new enum value, with a new name and a new number
//!   - a key type for a new enum value
//!   - a new field after the end of a sized struct
//!   - a new function, once `symbols.txt` lists it
//!
//! Anything else is reported, one problem per line, and the check fails.
//! For example, swapping two enum values prints:
//!
//! ```
//! GhosttyCursorStyle.values.BAR: golden 0, now 1
//! GhosttyCursorStyle.values.BLOCK: golden 1, now 0
//! ```
//!
//! ## Running the Check
//!
//! Use the build steps, which pass the right paths for the target:
//!
//! ```
//! zig build test-lib-vt-abi
//! zig build test-lib-vt-abi -Dtarget=wasm32-freestanding
//! ```
//!
//! After an intentional addition, write the new goldens for a target with:
//!
//! ```
//! zig build update-lib-vt-abi -Dtarget=x86_64-linux-gnu
//! ```
//!
//! ## How It Reads the Library
//!
//! The check never runs the library, so a cross-compiled target works the
//! same as the host. The manifest is one NUL-terminated string in the
//! library's data, so it is found by its first bytes. Exported symbols are
//! read directly from the ELF, Mach-O or WebAssembly file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Manifest fields that describe a build, not the ABI.
const build_fields = [_][]const u8{ "library_version", "commit", "dirty" };

/// Exports the WebAssembly linker adds to every module.
const wasm_runtime_exports = [_][]const u8{
    "memory",
    "__stack_pointer",
    "__indirect_function_table",
};

/// WebAssembly-only helpers start with this. `symbols.txt` doesn't list them
/// because they aren't exported on any other target.
const wasm_prefix = "ghostty_wasm_";

/// The command that records an intentional addition.
const update_hint = "zig build update-lib-vt-abi";

pub fn main(init: std.process.Init) !void {
    // This runs once and exits, so nothing is ever freed.
    const alloc = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 7) fatal(
        "usage: check <check|update> <library> <golden> <symbols> <lib_vt.zig> <headers>",
        .{},
    );
    const update = if (std.mem.eql(u8, args[1], "update"))
        true
    else if (std.mem.eql(u8, args[1], "check"))
        false
    else
        fatal("unknown mode, expected check or update: {s}", .{args[1]});
    const library_path = args[2];
    const golden_path = args[3];
    const symbols_path = args[4];

    const cwd = std.Io.Dir.cwd();
    const library = try cwd.readFileAlloc(io, library_path, alloc, .unlimited);
    const manifest = try parseManifest(alloc, try findManifest(library));
    const source = try sourceExports(
        alloc,
        try cwd.readFileAlloc(io, args[5], alloc, .unlimited),
    );

    if (update) {
        try cwd.writeFile(io, .{
            .sub_path = golden_path,
            .data = try goldenBytes(alloc, manifest),
        });
        try cwd.writeFile(io, .{
            .sub_path = symbols_path,
            .data = try symbolsBytes(alloc, source.public),
        });
        return;
    }

    var report: Report = .{ .alloc = alloc };

    if (cwd.readFileAlloc(io, golden_path, alloc, .unlimited)) |golden_bytes| {
        const golden = try parseManifest(alloc, golden_bytes);
        try compareManifests(&report, golden, manifest);
    } else |err| switch (err) {
        error.FileNotFound => try report.add(
            "{s}: no golden manifest for this target",
            .{golden_path},
        ),
        else => return err,
    }

    try checkSymbols(&report, .{
        .committed = try parseSymbols(
            alloc,
            try cwd.readFileAlloc(io, symbols_path, alloc, .unlimited),
        ),
        .source = source,
        .headers = try readHeaders(alloc, io, args[6]),
        .exports = try libraryExports(alloc, library),
    });

    if (report.additions > 0) std.debug.print(
        "libghostty-vt ABI: {d} addition(s) not in the goldens, " ++
            "run `" ++ update_hint ++ "` to record them\n",
        .{report.additions},
    );

    if (report.problems.items.len == 0) return;
    for (report.problems.items) |problem| std.debug.print("{s}\n", .{problem});
    std.debug.print(
        "\nlibghostty-vt ABI check failed with {d} problem(s). See " ++
            "src/terminal/c/AGENTS.md. A change that isn't an addition needs a " ++
            "new major version.\n",
        .{report.problems.items.len},
    );
    std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}

/// Collects every problem so that one run reports all of them.
const Report = struct {
    alloc: Allocator,
    problems: std.ArrayList([]const u8) = .empty,

    /// How many allowed changes aren't recorded in the goldens yet. These
    /// don't fail the check. They only print a reminder to update.
    additions: usize = 0,

    fn add(self: *Report, comptime format: []const u8, args: anytype) !void {
        try self.problems.append(
            self.alloc,
            try std.fmt.allocPrint(self.alloc, format, args),
        );
    }
};

/// Returns the manifest embedded in a library, without its NUL terminator.
fn findManifest(library: []const u8) ![]const u8 {
    const start = std.mem.find(u8, library, "{\"schema\":") orelse
        return error.ManifestNotFound;
    const len = std.mem.findScalar(u8, library[start..], 0) orelse
        return error.ManifestNotFound;
    return library[start..][0..len];
}

/// Parses a manifest from a library or a golden and removes the fields that
/// describe the build, so that the two can be compared.
fn parseManifest(alloc: Allocator, bytes: []const u8) !Value {
    var value = try std.json.parseFromSliceLeaky(Value, alloc, bytes, .{});
    for (build_fields) |field| _ = value.object.orderedRemove(field);
    return value;
}

/// The contents of a golden file for a manifest from `parseManifest`.
fn goldenBytes(alloc: Allocator, manifest: Value) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(
        alloc,
        manifest,
        .{ .whitespace = .indent_2 },
    );
    return std.fmt.allocPrint(alloc, "{s}\n", .{json});
}

/// Reports every difference between the golden and the current manifest
/// that isn't an allowed addition. See the top of this file for the rules.
fn compareManifests(report: *Report, golden: Value, current: Value) !void {
    try compareObject(
        report,
        "manifest",
        golden.object,
        current.object,
        &.{"types"},
    );

    const golden_types = golden.object.get("types").?.object;
    const current_types = current.object.get("types").?.object;

    var it = golden_types.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const current_type = current_types.get(name) orelse {
            try report.add("{s}: type removed", .{name});
            continue;
        };
        try compareType(report, name, entry.value_ptr.object, current_type.object);
    }

    for (current_types.keys()) |name| {
        if (!golden_types.contains(name)) report.additions += 1;
    }
}

/// Compares one type. Enums and sized structs have their own rules. Every
/// other kind of type must match the golden exactly.
fn compareType(
    report: *Report,
    name: []const u8,
    golden: ObjectMap,
    current: ObjectMap,
) !void {
    const kind = golden.get("kind").?.string;
    if (std.mem.eql(u8, kind, "enum")) {
        try compareObject(report, name, golden, current, &.{ "values", "keys" });
        try compareEnum(report, name, golden, current);
    } else if (std.mem.eql(u8, kind, "struct") and isSized(golden)) {
        try compareObject(report, name, golden, current, &.{ "fields", "size" });
        try compareSized(report, name, golden, current);
    } else {
        try compareObject(report, name, golden, current, &.{});
    }
}

/// An enum may gain values with new names and new numbers, and keys for
/// those new values. Everything it already has must stay as it is.
fn compareEnum(
    report: *Report,
    name: []const u8,
    golden: ObjectMap,
    current: ObjectMap,
) !void {
    const golden_values = golden.get("values").?.object;
    const current_values = current.get("values").?.object;

    var it = golden_values.iterator();
    while (it.next()) |entry| {
        const path = try childPath(report.alloc, name, "values", entry.key_ptr.*);
        const value = current_values.get(entry.key_ptr.*) orelse {
            try report.add("{s}: removed", .{path});
            continue;
        };
        try compareValue(report, path, entry.value_ptr.*, value);
    }

    var current_it = current_values.iterator();
    while (current_it.next()) |entry| {
        if (golden_values.contains(entry.key_ptr.*)) continue;
        report.additions += 1;
        for (golden_values.keys(), golden_values.values()) |existing, value| {
            if (!valueEql(value, entry.value_ptr.*)) continue;
            try report.add("{s}: new value reuses the number of {s}", .{
                try childPath(report.alloc, name, "values", entry.key_ptr.*),
                existing,
            });
        }
    }

    const empty: ObjectMap = .empty;
    const golden_keys = if (golden.get("keys")) |v| v.object else empty;
    const current_keys = if (current.get("keys")) |v| v.object else empty;

    var keys_it = golden_keys.iterator();
    while (keys_it.next()) |entry| {
        const path = try childPath(report.alloc, name, "keys", entry.key_ptr.*);
        const value = current_keys.get(entry.key_ptr.*) orelse {
            try report.add("{s}: removed", .{path});
            continue;
        };
        try compareValue(report, path, entry.value_ptr.*, value);
    }

    for (current_keys.keys()) |key| {
        if (golden_keys.contains(key)) continue;
        if (golden_values.contains(key)) try report.add(
            "{s}: an existing value gained a key type",
            .{try childPath(report.alloc, name, "keys", key)},
        );
    }
}

/// Returns true for a sized struct, which is one that starts with a `size`
/// field. The caller sets that field, so the library knows which fields
/// the caller's version of the struct has. That's why these structs can grow.
fn isSized(struct_type: ObjectMap) bool {
    const fields = struct_type.get("fields").?.object;
    if (fields.count() == 0) return false;
    if (!std.mem.eql(u8, fields.keys()[0], "size")) return false;
    return fields.values()[0].object.get("offset").?.integer == 0;
}

/// A sized struct may gain fields after the end of its golden layout, and
/// grow to hold them. Its existing fields must stay as they are.
fn compareSized(
    report: *Report,
    name: []const u8,
    golden: ObjectMap,
    current: ObjectMap,
) !void {
    const golden_fields = golden.get("fields").?.object;
    const current_fields = current.get("fields").?.object;
    const golden_size = golden.get("size").?.integer;
    const current_size = current.get("size").?.integer;

    var it = golden_fields.iterator();
    while (it.next()) |entry| {
        const path = try childPath(report.alloc, name, "fields", entry.key_ptr.*);
        const value = current_fields.get(entry.key_ptr.*) orelse {
            try report.add("{s}: removed", .{path});
            continue;
        };
        try compareValue(report, path, entry.value_ptr.*, value);
    }

    var appended = false;
    var current_it = current_fields.iterator();
    while (current_it.next()) |entry| {
        if (golden_fields.contains(entry.key_ptr.*)) continue;
        appended = true;
        report.additions += 1;
        const offset = entry.value_ptr.object.get("offset").?.integer;
        if (offset < golden_size) try report.add(
            "{s}: new field at offset {d} is inside the golden size {d}",
            .{
                try childPath(report.alloc, name, "fields", entry.key_ptr.*),
                offset,
                golden_size,
            },
        );
    }

    if (current_size < golden_size or (current_size > golden_size and !appended)) {
        try report.add("{s}.size: golden {d}, now {d}", .{
            name,
            golden_size,
            current_size,
        });
    }
}

fn childPath(
    alloc: Allocator,
    parent: []const u8,
    group: []const u8,
    name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ parent, group, name });
}

/// Compares two objects exactly, apart from the fields in `skip`. Callers
/// use `skip` for the fields they compare with their own rules.
fn compareObject(
    report: *Report,
    path: []const u8,
    golden: ObjectMap,
    current: ObjectMap,
    skip: []const []const u8,
) Allocator.Error!void {
    var it = golden.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (contains(skip, key)) continue;
        const child = try std.fmt.allocPrint(report.alloc, "{s}.{s}", .{ path, key });
        const value = current.get(key) orelse {
            try report.add("{s}: removed", .{child});
            continue;
        };
        try compareValue(report, child, entry.value_ptr.*, value);
    }

    for (current.keys()) |key| {
        if (contains(skip, key) or golden.contains(key)) continue;
        try report.add("{s}.{s}: added", .{ path, key });
    }
}

fn compareValue(
    report: *Report,
    path: []const u8,
    golden: Value,
    current: Value,
) Allocator.Error!void {
    if (golden == .object and current == .object) {
        return compareObject(report, path, golden.object, current.object, &.{});
    }

    if (valueEql(golden, current)) return;
    try report.add("{s}: golden {s}, now {s}", .{
        path,
        try std.json.Stringify.valueAlloc(report.alloc, golden, .{}),
        try std.json.Stringify.valueAlloc(report.alloc, current, .{}),
    });
}

fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| {
            if (v.items.len != b.array.items.len) return false;
            for (v.items, b.array.items) |x, y| if (!valueEql(x, y)) return false;
            return true;
        },
        .object => |v| {
            if (v.count() != b.object.count()) return false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!valueEql(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Names = std.ArrayList([]const u8);

/// The functions `src/lib_vt.zig` exports.
const SourceExports = struct {
    /// Exported on every target. This is what `symbols.txt` lists.
    public: []const []const u8,

    /// Exported on WebAssembly only.
    wasm: []const []const u8,
};

/// Finds the `ghostty_*` names in the `@export` calls of `src/lib_vt.zig`.
fn sourceExports(alloc: Allocator, source: []const u8) !SourceExports {
    var public: Names = .empty;
    var wasm: Names = .empty;

    const marker = ".name = \"";
    var pos: usize = 0;
    while (std.mem.findPos(u8, source, pos, marker)) |found| {
        const start = found + marker.len;
        const end = std.mem.findScalarPos(u8, source, start, '"') orelse
            return error.InvalidSource;
        pos = end;

        const name = source[start..end];
        if (!std.mem.startsWith(u8, name, "ghostty_")) continue;
        const list = if (std.mem.startsWith(u8, name, wasm_prefix)) &wasm else &public;
        try list.append(alloc, name);
    }

    return .{ .public = public.items, .wasm = wasm.items };
}

/// The contents of `symbols.txt` for a list of names, in any order.
fn symbolsBytes(alloc: Allocator, names: []const []const u8) ![]const u8 {
    const sorted = try alloc.dupe([]const u8, names);
    std.mem.sort([]const u8, sorted, {}, lessThan);

    var out: std.Io.Writer.Allocating = .init(alloc);
    for (sorted) |name| try out.writer.print("{s}\n", .{name});
    return out.written();
}

/// Parses `symbols.txt`, which has one name per line.
fn parseSymbols(alloc: Allocator, bytes: []const u8) ![]const []const u8 {
    var names: Names = .empty;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |name| try names.append(alloc, name);
    return names.items;
}

/// Returns the `GHOSTTY_API` functions of the public vt headers.
fn readHeaders(
    alloc: Allocator,
    io: std.Io,
    include_path: []const u8,
) ![]const []const u8 {
    var names: Names = .empty;

    const dir = try std.Io.Dir.cwd().openDir(io, include_path, .{ .iterate = true });
    try headerFunctions(
        alloc,
        &names,
        try dir.readFileAlloc(io, "vt.h", alloc, .unlimited),
    );

    const vt = try dir.openDir(io, "vt", .{ .iterate = true });
    var walker = try vt.walk(alloc);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".h")) continue;
        try headerFunctions(
            alloc,
            &names,
            try vt.readFileAlloc(io, entry.path, alloc, .unlimited),
        );
    }

    return names.items;
}

/// Appends the name of the function declared after each `GHOSTTY_API` in a
/// header. Comments and preprocessor lines are skipped, so a mention in a
/// doc comment or the macro's own definition doesn't count.
fn headerFunctions(alloc: Allocator, names: *Names, header: []const u8) !void {
    const marker = "GHOSTTY_API";

    var pos: usize = 0;
    while (pos < header.len) {
        const rest = header[pos..];
        if (std.mem.startsWith(u8, rest, "/*")) {
            const end = std.mem.findPos(u8, header, pos, "*/") orelse return;
            pos = end + 2;
        } else if (std.mem.startsWith(u8, rest, "//") or
            (rest[0] == '#' and atLineStart(header, pos)))
        {
            pos = std.mem.findScalarPos(u8, header, pos, '\n') orelse return;
        } else if (std.mem.startsWith(u8, rest, marker)) {
            const paren = std.mem.findScalarPos(u8, header, pos, '(') orelse
                return error.InvalidHeader;
            var start = paren;
            while (start > pos and isIdentifier(header[start - 1])) start -= 1;
            try names.append(alloc, header[start..paren]);
            pos = paren;
        } else {
            pos += 1;
        }
    }
}

fn atLineStart(text: []const u8, pos: usize) bool {
    var i = pos;
    while (i > 0) : (i -= 1) switch (text[i - 1]) {
        ' ', '\t' => {},
        '\n' => return true,
        else => return false,
    };
    return true;
}

fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Returns the names of everything a shared library or WebAssembly module
/// exports.
fn libraryExports(alloc: Allocator, library: []const u8) ![]const []const u8 {
    if (std.mem.startsWith(u8, library, std.elf.MAGIC)) return elfExports(alloc, library);
    if (std.mem.startsWith(u8, library, std.wasm.magic[0..])) return wasmExports(alloc, library);
    if (library.len >= 4 and
        std.mem.readInt(u32, library[0..4], .little) == std.macho.MH_MAGIC_64)
    {
        return machoExports(alloc, library);
    }
    return error.UnsupportedLibraryFormat;
}

/// Reads the defined global symbols of the `.dynsym` section, the same set
/// as `llvm-nm -D --defined-only`. Only little-endian ELF64 is supported,
/// which covers every target that has a golden.
fn elfExports(alloc: Allocator, library: []const u8) ![]const []const u8 {
    if (library[std.elf.EI.CLASS] != std.elf.ELFCLASS64 or
        library[std.elf.EI.DATA] != std.elf.ELFDATA2LSB)
    {
        return error.UnsupportedLibraryFormat;
    }

    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, library);
    const Shdr = std.elf.Elf64_Shdr;
    const Sym = std.elf.Elf64_Sym;

    var names: Names = .empty;
    for (0..header.e_shnum) |i| {
        const section = std.mem.bytesToValue(
            Shdr,
            library[header.e_shoff + i * header.e_shentsize ..],
        );
        if (section.sh_type != std.elf.SHT_DYNSYM) continue;

        const strings = std.mem.bytesToValue(
            Shdr,
            library[header.e_shoff + section.sh_link * header.e_shentsize ..],
        );
        const count = section.sh_size / @sizeOf(Sym);
        for (0..count) |j| {
            const sym = std.mem.bytesToValue(
                Sym,
                library[section.sh_offset + j * @sizeOf(Sym) ..],
            );
            if (sym.st_shndx == std.elf.SHN_UNDEF) continue;
            const binding = sym.st_info >> 4;
            if (binding != std.elf.STB_GLOBAL and binding != std.elf.STB_WEAK) continue;
            try names.append(alloc, std.mem.sliceTo(
                library[strings.sh_offset + sym.st_name ..],
                0,
            ));
        }
    }
    return names.items;
}

/// Reads the defined external symbols of the `LC_SYMTAB` load command, the
/// same set as `nm -gU`.
fn machoExports(alloc: Allocator, library: []const u8) ![]const []const u8 {
    const macho = std.macho;
    const header = std.mem.bytesToValue(macho.mach_header_64, library);

    var names: Names = .empty;
    var offset: usize = @sizeOf(macho.mach_header_64);
    for (0..header.ncmds) |_| {
        const command = std.mem.bytesToValue(macho.load_command, library[offset..]);
        defer offset += command.cmdsize;
        if (command.cmd != .SYMTAB) continue;

        const symtab = std.mem.bytesToValue(macho.symtab_command, library[offset..]);
        for (0..symtab.nsyms) |i| {
            const sym = std.mem.bytesToValue(
                macho.nlist_64,
                library[symtab.symoff + i * @sizeOf(macho.nlist_64) ..],
            );
            const flags: u8 = @bitCast(sym.n_type);
            if (flags & macho.N_STAB != 0) continue;
            if (flags & macho.N_EXT == 0) continue;
            if (flags & macho.N_TYPE == macho.N_UNDF) continue;

            // C symbols have a leading underscore in Mach-O.
            const name = std.mem.sliceTo(library[symtab.stroff + sym.n_strx ..], 0);
            try names.append(alloc, name[1..]);
        }
    }
    return names.items;
}

/// Reads the export section of a WebAssembly module.
fn wasmExports(alloc: Allocator, library: []const u8) ![]const []const u8 {
    const export_section = 7;

    var names: Names = .empty;
    var reader: std.Io.Reader = .fixed(library[8..]);
    while (reader.seek < reader.end) {
        const id = try reader.takeByte();
        const size = try reader.takeLeb128(u32);
        if (id != export_section) {
            try reader.discardAll(size);
            continue;
        }

        const count = try reader.takeLeb128(u32);
        for (0..count) |_| {
            const len = try reader.takeLeb128(u32);
            try names.append(alloc, try reader.take(len));
            _ = try reader.takeByte(); // kind
            _ = try reader.takeLeb128(u32); // index
        }
    }
    return names.items;
}

/// The four views of the public functions that `checkSymbols` compares.
const SymbolInputs = struct {
    /// The names in `symbols.txt`.
    committed: []const []const u8,

    /// The names `src/lib_vt.zig` exports.
    source: SourceExports,

    /// The names the headers declare with `GHOSTTY_API`.
    headers: []const []const u8,

    /// The names the built library really exports.
    exports: []const []const u8,
};

/// Checks that `symbols.txt`, `src/lib_vt.zig`, the headers and the built
/// library all list the same functions. A function that is removed from the
/// source fails here, and so does one that is added but not yet recorded in
/// `symbols.txt`. On WebAssembly, the library may also export the
/// `ghostty_wasm_*` helpers and `wasm_runtime_exports`.
fn checkSymbols(report: *Report, inputs: SymbolInputs) !void {
    const alloc = report.alloc;
    const committed = inputs.committed;
    const source = inputs.source;

    for (committed) |name| if (!contains(source.public, name)) try report.add(
        "{s}: in symbols.txt but src/lib_vt.zig doesn't export it, " ++
            "removing a symbol breaks the ABI",
        .{name},
    );
    for (source.public) |name| if (!contains(committed, name)) try report.add(
        "{s}: src/lib_vt.zig exports it but it isn't in symbols.txt, " ++
            "run `" ++ update_hint ++ "`",
        .{name},
    );

    var headers: Names = .empty;
    var wasm_headers: Names = .empty;
    for (inputs.headers) |name| {
        const list = if (std.mem.startsWith(u8, name, wasm_prefix)) &wasm_headers else &headers;
        try list.append(alloc, name);
    }
    for (headers.items) |name| if (!contains(committed, name)) try report.add(
        "{s}: the headers declare it but it isn't in symbols.txt",
        .{name},
    );
    for (committed) |name| if (!contains(headers.items, name)) try report.add(
        "{s}: in symbols.txt but no header declares it",
        .{name},
    );
    for (wasm_headers.items) |name| if (!contains(source.wasm, name)) try report.add(
        "{s}: the headers declare it but src/lib_vt.zig doesn't export it",
        .{name},
    );
    for (source.wasm) |name| if (!contains(wasm_headers.items, name)) try report.add(
        "{s}: src/lib_vt.zig exports it but no header declares it",
        .{name},
    );

    // Only WebAssembly modules export their memory.
    const is_wasm = contains(inputs.exports, "memory");
    var expected: Names = .empty;
    try expected.appendSlice(alloc, committed);
    if (is_wasm) {
        try expected.appendSlice(alloc, source.wasm);
        try expected.appendSlice(alloc, &wasm_runtime_exports);
    }
    for (expected.items) |name| if (!contains(inputs.exports, name)) try report.add(
        "{s}: the built library doesn't export it",
        .{name},
    );
    for (inputs.exports) |name| if (!contains(expected.items, name)) try report.add(
        "{s}: the built library exports it but it isn't in symbols.txt",
        .{name},
    );
}

test "compareManifests" {
    const base =
        \\{"schema":1,"abi":{"target":"x"},"types":{
        \\"E":{"kind":"enum","size":4,"underlying":"i32","prefix":"E_",
        \\  "values":{"A":0,"B":1},"keys":{"B":{"type":"u8"}}},
        \\"S":{"kind":"struct","size":16,"align":8,"fields":{
        \\  "size":{"offset":0,"size":8,"type":"u64"},
        \\  "a":{"offset":8,"size":4,"type":"u32"}}},
        \\"F":{"kind":"struct","size":8,"align":4,"fields":{
        \\  "a":{"offset":0,"size":4,"type":"u32"},
        \\  "b":{"offset":4,"size":4,"type":"u32"}}},
        \\"C":{"kind":"callback","size":8,"params":["u32"],"return":"void"}
        \\}}
    ;

    const Case = struct {
        /// The text to replace in `base`, and what to replace it with.
        find: []const u8,
        replace: []const u8,

        /// The expected problem, or null if the change is allowed.
        problem: ?[]const u8,
        additions: usize = 0,
    };

    const cases = [_]Case{
        .{ .find = "", .replace = "", .problem = null },

        // Types
        .{
            .find = "\"C\":",
            .replace = "\"New\":{\"kind\":\"opaque\"},\"C\":",
            .problem = null,
            .additions = 1,
        },
        .{
            .find = "\"C\":{\"kind\":\"callback\"",
            .replace = "\"D\":{\"kind\":\"callback\"",
            .problem = "C: type removed",
            .additions = 1,
        },
        .{
            .find = "\"schema\":1",
            .replace = "\"schema\":2",
            .problem = "manifest.schema: golden 1, now 2",
        },
        .{
            .find = "\"target\":\"x\"",
            .replace = "\"target\":\"y\"",
            .problem = "manifest.abi.target: golden \"x\", now \"y\"",
        },

        // Enums
        .{
            .find = "\"B\":1}",
            .replace = "\"B\":1,\"C\":2}",
            .problem = null,
            .additions = 1,
        },
        .{
            .find = "\"B\":1}",
            .replace = "\"B\":1,\"C\":1}",
            .problem = "E.values.C: new value reuses the number of B",
            .additions = 1,
        },
        .{
            .find = "\"A\":0,\"B\":1",
            .replace = "\"A\":1,\"B\":0",
            .problem = "E.values.A: golden 0, now 1",
        },
        .{
            .find = "\"A\":0,",
            .replace = "",
            .problem = "E.values.A: removed",
        },
        .{
            .find = "\"prefix\":\"E_\"",
            .replace = "\"prefix\":\"F_\"",
            .problem = "E.prefix: golden \"E_\", now \"F_\"",
        },
        .{
            .find = "\"underlying\":\"i32\"",
            .replace = "\"underlying\":\"u32\"",
            .problem = "E.underlying: golden \"i32\", now \"u32\"",
        },
        .{
            .find = "\"keys\":{\"B\":{\"type\":\"u8\"}}",
            .replace = "\"keys\":{\"B\":{\"type\":\"u16\"}}",
            .problem = "E.keys.B.type: golden \"u8\", now \"u16\"",
        },
        .{
            .find = "\"keys\":{\"B\":{\"type\":\"u8\"}}",
            .replace = "\"keys\":{}",
            .problem = "E.keys.B: removed",
        },
        .{
            .find = "\"keys\":{\"B\":{\"type\":\"u8\"}}",
            .replace = "\"keys\":{\"A\":{\"type\":\"u8\"},\"B\":{\"type\":\"u8\"}}",
            .problem = "E.keys.A: an existing value gained a key type",
        },
        .{
            .find = "\"B\":1},\"keys\":{",
            .replace = "\"B\":1,\"C\":2},\"keys\":{\"C\":{\"type\":\"u8\"},",
            .problem = null,
            .additions = 1,
        },

        // Sized structs
        .{
            .find = "\"size\":16,\"align\":8,\"fields\":{",
            .replace = "\"size\":24,\"align\":8,\"fields\":{",
            .problem = "S.size: golden 16, now 24",
        },
        .{
            .find = "\"size\":16,\"align\":8,\"fields\":{",
            .replace = "\"size\":8,\"align\":8,\"fields\":{",
            .problem = "S.size: golden 16, now 8",
        },
        .{
            .find = "\"size\":16,\"align\":8,\"fields\":{",
            .replace = "\"size\":16,\"align\":4,\"fields\":{",
            .problem = "S.align: golden 8, now 4",
        },
        .{
            .find = "\"a\":{\"offset\":8,\"size\":4,\"type\":\"u32\"}",
            .replace = "\"a\":{\"offset\":12,\"size\":4,\"type\":\"u32\"}",
            .problem = "S.fields.a.offset: golden 8, now 12",
        },
        .{
            .find = "\"a\":{\"offset\":8,\"size\":4,\"type\":\"u32\"}",
            .replace = "\"a\":{\"offset\":8,\"size\":4,\"type\":\"u32\"}," ++
                "\"b\":{\"offset\":12,\"size\":4,\"type\":\"u32\"}",
            .problem = "S.fields.b: new field at offset 12 is inside the golden size 16",
            .additions = 1,
        },

        // Frozen structs and everything else
        .{
            .find = "\"b\":{\"offset\":4,\"size\":4,\"type\":\"u32\"}",
            .replace = "\"b\":{\"offset\":4,\"size\":4,\"type\":\"i32\"}",
            .problem = "F.fields.b.type: golden \"u32\", now \"i32\"",
        },
        .{
            .find = "\"b\":{\"offset\":4,\"size\":4,\"type\":\"u32\"}",
            .replace = "\"b\":{\"offset\":4,\"size\":4,\"type\":\"u32\"}," ++
                "\"c\":{\"offset\":8,\"size\":4,\"type\":\"u32\"}",
            .problem = "F.fields.c: added",
        },
        .{
            .find = "\"params\":[\"u32\"]",
            .replace = "\"params\":[\"u64\"]",
            .problem = "C.params: golden [\"u32\"], now [\"u64\"]",
        },
    };

    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const changed = if (case.find.len == 0)
            base
        else
            try std.mem.replaceOwned(u8, alloc, base, case.find, case.replace);
        try std.testing.expect(case.find.len == 0 or !std.mem.eql(u8, base, changed));

        var report: Report = .{ .alloc = alloc };
        try compareManifests(
            &report,
            try parseManifest(alloc, base),
            try parseManifest(alloc, changed),
        );

        try std.testing.expectEqual(case.additions, report.additions);
        if (case.problem) |problem| {
            try std.testing.expect(report.problems.items.len > 0);
            try std.testing.expectEqualStrings(problem, report.problems.items[0]);
        } else {
            try std.testing.expectEqual(0, report.problems.items.len);
        }
    }
}

test "sized struct may append a field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var report: Report = .{ .alloc = alloc };
    try compareManifests(
        &report,
        try parseManifest(alloc,
            \\{"types":{"S":{"kind":"struct","size":16,"fields":{
            \\  "size":{"offset":0},"a":{"offset":8}}}}}
        ),
        try parseManifest(alloc,
            \\{"types":{"S":{"kind":"struct","size":24,"fields":{
            \\  "size":{"offset":0},"a":{"offset":8},"b":{"offset":16}}}}}
        ),
    );
    try std.testing.expectEqual(0, report.problems.items.len);
    try std.testing.expectEqual(1, report.additions);
}

test "build fields are ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var report: Report = .{ .alloc = alloc };
    try compareManifests(
        &report,
        try parseManifest(alloc,
            \\{"library_version":"1","commit":"a","dirty":null,"types":{}}
        ),
        try parseManifest(alloc,
            \\{"library_version":"2","commit":"b","dirty":true,"types":{}}
        ),
    );
    try std.testing.expectEqual(0, report.problems.items.len);
}

test "findManifest" {
    try std.testing.expectEqualStrings(
        "{\"schema\":1}",
        try findManifest("\x00\x01{\"schema\":1}\x00\x02"),
    );
    try std.testing.expectError(error.ManifestNotFound, findManifest("nothing"));
    try std.testing.expectError(error.ManifestNotFound, findManifest("{\"schema\":1}"));
}

test "sourceExports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = try sourceExports(arena.allocator(),
        \\@export(&msvc_fltused, .{ .name = "_fltused" });
        \\@export(&c.a, .{ .name = "ghostty_a" });
        \\@export(&alloc.b, .{ .name = "ghostty_wasm_b" });
    );
    try std.testing.expectEqual(1, result.public.len);
    try std.testing.expectEqualStrings("ghostty_a", result.public[0]);
    try std.testing.expectEqual(1, result.wasm.len);
    try std.testing.expectEqualStrings("ghostty_wasm_b", result.wasm[0]);
}

test "headerFunctions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var names: Names = .empty;
    try headerFunctions(alloc, &names,
        \\#ifndef GHOSTTY_API
        \\  #define GHOSTTY_API __attribute__((visibility("default")))
        \\#endif
        \\/* GHOSTTY_API void in_comment(void); */
        \\// GHOSTTY_API void in_line_comment(void);
        \\GHOSTTY_API const char *ghostty_a(void);
        \\GHOSTTY_API GhosttyResult ghostty_b(int a,
        \\                                    int b);
        \\GHOSTTY_API void* ghostty_c(size_t len);
    );

    try std.testing.expectEqual(3, names.items.len);
    try std.testing.expectEqualStrings("ghostty_a", names.items[0]);
    try std.testing.expectEqualStrings("ghostty_b", names.items[1]);
    try std.testing.expectEqualStrings("ghostty_c", names.items[2]);
}

test "wasmExports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const names = try wasmExports(
        arena.allocator(),
        "\x00asm\x01\x00\x00\x00" ++
            "\x01\x02\xaa\xbb" ++ // another section
            "\x07\x0b\x02" ++
            "\x01a\x00\x05" ++
            "\x03abc\x02\x80\x01",
    );
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("a", names[0]);
    try std.testing.expectEqualStrings("abc", names[1]);
}

test "checkSymbols" {
    const Case = struct {
        committed: []const []const u8 = &.{"ghostty_a"},
        public: []const []const u8 = &.{"ghostty_a"},
        headers: []const []const u8 = &.{"ghostty_a"},
        exports: []const []const u8 = &.{"ghostty_a"},
        problem: ?[]const u8 = null,
    };

    const cases = [_]Case{
        .{},
        .{
            .public = &.{},
            .problem = "ghostty_a: in symbols.txt but src/lib_vt.zig doesn't export it, " ++
                "removing a symbol breaks the ABI",
        },
        .{
            .public = &.{ "ghostty_a", "ghostty_b" },
            .problem = "ghostty_b: src/lib_vt.zig exports it but it isn't in symbols.txt, " ++
                "run `zig build update-lib-vt-abi`",
        },
        .{
            .headers = &.{ "ghostty_a", "ghostty_b" },
            .problem = "ghostty_b: the headers declare it but it isn't in symbols.txt",
        },
        .{
            .headers = &.{},
            .problem = "ghostty_a: in symbols.txt but no header declares it",
        },
        .{
            .exports = &.{},
            .problem = "ghostty_a: the built library doesn't export it",
        },
        .{
            .exports = &.{ "ghostty_a", "ghostty_simd_index_of" },
            .problem = "ghostty_simd_index_of: the built library exports it " ++
                "but it isn't in symbols.txt",
        },
    };

    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();

        var report: Report = .{ .alloc = arena.allocator() };
        try checkSymbols(&report, .{
            .committed = case.committed,
            .source = .{ .public = case.public, .wasm = &.{} },
            .headers = case.headers,
            .exports = case.exports,
        });

        if (case.problem) |problem| {
            try std.testing.expectEqual(1, report.problems.items.len);
            try std.testing.expectEqualStrings(problem, report.problems.items[0]);
        } else {
            try std.testing.expectEqual(0, report.problems.items.len);
        }
    }
}

test "checkSymbols allows the WebAssembly extras only on WebAssembly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: SourceExports = .{
        .public = &.{"ghostty_a"},
        .wasm = &.{"ghostty_wasm_b"},
    };
    const headers: []const []const u8 = &.{ "ghostty_a", "ghostty_wasm_b" };

    var wasm: Report = .{ .alloc = alloc };
    try checkSymbols(&wasm, .{
        .committed = &.{"ghostty_a"},
        .source = source,
        .headers = headers,
        .exports = &.{
            "memory",
            "__stack_pointer",
            "__indirect_function_table",
            "ghostty_a",
            "ghostty_wasm_b",
        },
    });
    try std.testing.expectEqual(0, wasm.problems.items.len);

    var native: Report = .{ .alloc = alloc };
    try checkSymbols(&native, .{
        .committed = &.{"ghostty_a"},
        .source = source,
        .headers = headers,
        .exports = &.{ "ghostty_a", "ghostty_wasm_b" },
    });
    try std.testing.expectEqual(1, native.problems.items.len);
    try std.testing.expectEqualStrings(
        "ghostty_wasm_b: the built library exports it but it isn't in symbols.txt",
        native.problems.items[0],
    );
}
