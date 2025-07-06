"""
This file extracts the patch sets from the nerd fonts font patcher file in order to
extract scaling rules and attributes for different codepoint ranges which it then
codegens in to a Zig file with a function that switches over codepoints and returns the
attributes and scaling rules.

This does include an `eval` call! This is spooky, but we trust the nerd fonts code to
be safe and not malicious or anything.
"""

import ast
import math
import sys
from collections import defaultdict
from contextlib import suppress
from types import SimpleNamespace
from typing import Literal, TypedDict, cast

type PatchSetAttributes = dict[Literal["default"] | int, PatchSetAttributeEntry]
type AttributeHash = tuple[str | None, str | None, str, float, float, float]
type ResolvedSymbol = PatchSetAttributes | PatchSetScaleRules | int | None


class PatchSetScaleRules(TypedDict):
    ShiftMode: str
    ScaleGroups: list[list[int] | range]


class PatchSetAttributeEntry(TypedDict):
    align: str
    valign: str
    stretch: str
    params: dict[str, float | bool]


class PatchSet(TypedDict):
    SymStart: int
    SymEnd: int
    SrcStart: int | None
    ScaleRules: PatchSetScaleRules | None
    Attributes: PatchSetAttributes


class PatchSetExtractor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.symbol_table: dict[str, ast.expr] = {}
        self.patch_set_values: list[PatchSet] = []

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        if node.name != "font_patcher":
            return
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "setup_patch_set":
                self.visit_setup_patch_set(item)

    def visit_setup_patch_set(self, node: ast.FunctionDef) -> None:
        # First pass: gather variable assignments
        for stmt in node.body:
            match stmt:
                case ast.Assign(targets=[ast.Name(id=symbol)]):
                    # Store simple variable assignments in the symbol table
                    self.symbol_table[symbol] = stmt.value

        # Second pass: process self.patch_set
        for stmt in node.body:
            if not isinstance(stmt, ast.Assign):
                continue
            for target in stmt.targets:
                if (
                    isinstance(target, ast.Attribute)
                    and target.attr == "patch_set"
                    and isinstance(stmt.value, ast.List)
                ):
                    for elt in stmt.value.elts:
                        if isinstance(elt, ast.Dict):
                            self.process_patch_entry(elt)

    def resolve_symbol(self, node: ast.expr) -> ResolvedSymbol:
        """Resolve named variables to their actual values from the symbol table."""
        if isinstance(node, ast.Name) and node.id in self.symbol_table:
            return self.safe_literal_eval(self.symbol_table[node.id])
        return self.safe_literal_eval(node)

    def safe_literal_eval(self, node: ast.expr) -> ResolvedSymbol:
        """Try to evaluate or stringify an AST node."""
        try:
            return ast.literal_eval(node)
        except ValueError:
            # Spooky eval! But we trust nerd fonts to be safe...
            if hasattr(ast, "unparse"):
                return eval(
                    ast.unparse(node),
                    {"box_keep": True},
                    {"self": SimpleNamespace(args=SimpleNamespace(careful=True))},
                )
            msg = f"<cannot eval: {type(node).__name__}>"
            raise ValueError(msg) from None

    def process_patch_entry(self, dict_node: ast.Dict) -> None:
        entry = {}
        disallowed_key_nodes = frozenset({"Enabled", "Name", "Filename", "Exact"})
        for key_node, value_node in zip(dict_node.keys, dict_node.values):
            if (
                isinstance(key_node, ast.Constant)
                and key_node.value not in disallowed_key_nodes
            ):
                key = ast.literal_eval(cast("ast.Constant", key_node))
                entry[key] = self.resolve_symbol(value_node)
        self.patch_set_values.append(cast("PatchSet", entry))


def extract_patch_set_values(source_code: str) -> list[PatchSet]:
    tree = ast.parse(source_code)
    extractor = PatchSetExtractor()
    extractor.visit(tree)
    return extractor.patch_set_values


def parse_alignment(val: str) -> str | None:
    return {
        "l": ".start",
        "r": ".end",
        "c": ".center",
        "": None,
    }.get(val, ".none")


def attr_key(attr: PatchSetAttributeEntry) -> AttributeHash:
    """Convert attributes to a hashable key for grouping."""
    params = attr.get("params", {})
    return (
        parse_alignment(attr.get("align", "")),
        parse_alignment(attr.get("valign", "")),
        attr.get("stretch", ""),
        float(params.get("overlap", 0.0)),
        float(params.get("xy-ratio", -1.0)),
        float(params.get("ypadding", 0.0)),
    )


def coalesce_codepoints_to_ranges(codepoints: list[int]) -> list[tuple[int, int]]:
    """Convert a sorted list of integers to a list of single values and ranges."""
    ranges: list[tuple[int, int]] = []
    cp_iter = iter(sorted(codepoints))
    with suppress(StopIteration):
        start = prev = next(cp_iter)
        for cp in cp_iter:
            if cp == prev + 1:
                prev = cp
            else:
                ranges.append((start, prev))
                start = prev = cp
        ranges.append((start, prev))
    return ranges


def emit_zig_entry_multikey(codepoints: list[int], attr: PatchSetAttributeEntry) -> str:
    align = parse_alignment(attr.get("align", ""))
    valign = parse_alignment(attr.get("valign", ""))
    stretch = attr.get("stretch", "")
    params = attr.get("params", {})

    overlap = params.get("overlap", 0.0)
    xy_ratio = params.get("xy-ratio", -1.0)
    y_padding = params.get("ypadding", 0.0)

    ranges = coalesce_codepoints_to_ranges(codepoints)
    keys = "\n".join(
        f"        {start:#x}...{end:#x}," if start != end else f"        {start:#x},"
        for start, end in ranges
    )

    s = f"{keys}\n        => .{{\n"

    # These translations don't quite capture the way
    # the actual patcher does scaling, but they're a
    # good enough compromise.
    if "xy" in stretch:
        s += "            .size_horizontal = .stretch,\n"
        s += "            .size_vertical = .stretch,\n"
    elif "!" in stretch:
        s += "            .size_horizontal = .cover,\n"
        s += "            .size_vertical = .fit,\n"
    elif "^" in stretch:
        s += "            .size_horizontal = .cover,\n"
        s += "            .size_vertical = .cover,\n"
    else:
        s += "            .size_horizontal = .fit,\n"
        s += "            .size_vertical = .fit,\n"

    if align is not None:
        s += f"            .align_horizontal = {align},\n"
    if valign is not None:
        s += f"            .align_vertical = {valign},\n"

    if overlap:
        pad = -overlap
        s += f"            .pad_left = {pad},\n"
        s += f"            .pad_right = {pad},\n"
        v_pad = y_padding - math.copysign(min(0.01, abs(overlap)), overlap)
        s += f"            .pad_top = {v_pad},\n"
        s += f"            .pad_bottom = {v_pad},\n"

    if xy_ratio > 0:
        s += f"            .max_xy_ratio = {xy_ratio},\n"

    s += "        },"
    return s


def generate_zig_switch_arms(patch_sets: list[PatchSet]) -> str:
    entries: dict[int, PatchSetAttributeEntry] = {}
    for entry in patch_sets:
        attributes = entry["Attributes"]

        for cp in range(entry["SymStart"], entry["SymEnd"] + 1):
            entries[cp] = attributes["default"]

        entries |= {k: v for k, v in attributes.items() if isinstance(k, int)}

    del entries[0]

    # Group codepoints by attribute key
    grouped = defaultdict[AttributeHash, list[int]](list)
    for cp, attr in entries.items():
        grouped[attr_key(attr)].append(cp)

    # Emit zig switch arms
    result: list[str] = []
    for codepoints in sorted(grouped.values()):
        # Use one of the attrs in the group to emit the value
        attr = entries[codepoints[0]]
        result.append(emit_zig_entry_multikey(codepoints, attr))

    return "\n".join(result)


if __name__ == "__main__":
    source = sys.stdin.read()
    patch_set = extract_patch_set_values(source)
    print("""//! This is a generated file, produced by nerd_font_codegen.py
//! DO NOT EDIT BY HAND!
//!
//! This file provides info extracted from the nerd fonts patcher script,
//! specifying the scaling/positioning attributes of various glyphs.

const Constraint = @import("face.zig").RenderOptions.Constraint;

/// Get the a constraints for the provided codepoint.
pub fn getConstraint(cp: u21) Constraint {
    return switch (cp) {""")
    print(generate_zig_switch_arms(patch_set))
    print("        else => .none,\n    };\n}")
