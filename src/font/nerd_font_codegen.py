"""
This file extracts the patch sets from the nerd fonts font patcher file in order to
extract scaling rules and attributes for different codepoint ranges which it then
codegens in to a Zig file with a function that switches over codepoints and returns the
attributes and scaling rules.

This does include an `eval` call! This is spooky, but we trust the nerd fonts code to
be safe and not malicious or anything.

This script requires Python 3.12 or greater, requires that the `fontTools`
python module is installed, and requires that the path to a copy of the
SymbolsNerdFont (not Mono!) font is passed as the first argument to it.
"""

import ast
import sys
import math
from fontTools.ttLib import TTFont
from fontTools.pens.boundsPen import BoundsPen
from collections import defaultdict
from contextlib import suppress
from pathlib import Path
from types import SimpleNamespace
from typing import Literal, TypedDict, cast

type PatchSetAttributes = dict[Literal["default"] | int, PatchSetAttributeEntry]
type AttributeHash = tuple[
    str | None,
    str | None,
    str,
    float,
    float,
    float,
    float,
    float,
    float,
    float,
]
type ResolvedSymbol = PatchSetAttributes | PatchSetScaleRules | int | None


class PatchSetScaleRules(TypedDict):
    ShiftMode: str
    ScaleGroups: list[list[int] | range]


class PatchSetAttributeEntry(TypedDict):
    align: str
    valign: str
    stretch: str
    params: dict[str, float | bool]

    group_x: float
    group_y: float
    group_width: float
    group_height: float


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
        float(attr.get("group_x", 0.0)),
        float(attr.get("group_y", 0.0)),
        float(attr.get("group_width", 1.0)),
        float(attr.get("group_height", 1.0)),
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

    group_x = attr.get("group_x", 0.0)
    group_y = attr.get("group_y", 0.0)
    group_width = attr.get("group_width", 1.0)
    group_height = attr.get("group_height", 1.0)

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
    elif "!" in stretch or "^" in stretch:
        s += "            .size_horizontal = .cover,\n"
        s += "            .size_vertical = .fit,\n"
    else:
        s += "            .size_horizontal = .fit,\n"
        s += "            .size_vertical = .fit,\n"

    # `^` indicates that scaling should fill
    # the whole cell, not just the icon height.
    if "^" not in stretch:
        s += "            .height = .icon,\n"

    # There are two cases where we want to limit the constraint width to 1:
    # - If there's a `1` in the stretch mode string.
    # - If the stretch mode is `xy` and there's not an explicit `2`.
    if "1" in stretch or ("xy" in stretch and "2" not in stretch):
        s += "            .max_constraint_width = 1,\n"

    if align is not None:
        s += f"            .align_horizontal = {align},\n"
    if valign is not None:
        s += f"            .align_vertical = {valign},\n"

    if group_width != 1.0:
        s += f"            .group_width = {group_width:.16f},\n"
    if group_height != 1.0:
        s += f"            .group_height = {group_height:.16f},\n"
    if group_x != 0.0:
        s += f"            .group_x = {group_x:.16f},\n"
    if group_y != 0.0:
        s += f"            .group_y = {group_y:.16f},\n"

    # `overlap` and `ypadding` are mutually exclusive,
    # this is asserted in the nerd fonts patcher itself.
    if overlap:
        pad = -overlap
        s += f"            .pad_left = {pad},\n"
        s += f"            .pad_right = {pad},\n"
        # In the nerd fonts patcher, overlap values
        # are capped at 0.01 in the vertical direction.
        v_pad = -min(0.01, overlap)
        s += f"            .pad_top = {v_pad},\n"
        s += f"            .pad_bottom = {v_pad},\n"
    elif y_padding:
        s += f"            .pad_top = {y_padding / 2},\n"
        s += f"            .pad_bottom = {y_padding / 2},\n"

    if xy_ratio > 0:
        s += f"            .max_xy_ratio = {xy_ratio},\n"

    s += "        },"
    return s


def generate_zig_switch_arms(
    patch_sets: list[PatchSet],
    nerd_font: TTFont,
) -> str:
    cmap = nerd_font.getBestCmap()
    glyphs = nerd_font.getGlyphSet()

    entries: dict[int, PatchSetAttributeEntry] = {}
    for entry in patch_sets:
        attributes = entry["Attributes"]

        for cp in range(entry["SymStart"], entry["SymEnd"] + 1):
            entries[cp] = attributes["default"].copy()

        entries |= {k: v for k, v in attributes.items() if isinstance(k, int)}

        if entry["ScaleRules"] is not None and "ScaleGroups" in entry["ScaleRules"]:
            for group in entry["ScaleRules"]["ScaleGroups"]:
                xMin = math.inf
                yMin = math.inf
                xMax = -math.inf
                yMax = -math.inf
                individual_bounds: dict[int, tuple[int, int, int ,int]] = {}
                for cp in group:
                    if cp not in cmap:
                        continue
                    glyph = glyphs[cmap[cp]]
                    bounds = BoundsPen(glyphSet=glyphs)
                    glyph.draw(bounds)
                    individual_bounds[cp] = bounds.bounds
                    xMin = min(bounds.bounds[0], xMin)
                    yMin = min(bounds.bounds[1], yMin)
                    xMax = max(bounds.bounds[2], xMax)
                    yMax = max(bounds.bounds[3], yMax)
                group_width = xMax - xMin
                group_height = yMax - yMin
                for cp in group:
                    if cp not in cmap or cp not in entries:
                        continue
                    this_bounds = individual_bounds[cp]
                    this_width = this_bounds[2] - this_bounds[0]
                    this_height = this_bounds[3] - this_bounds[1]
                    entries[cp]["group_width"] = group_width / this_width
                    entries[cp]["group_height"] = group_height / this_height
                    entries[cp]["group_x"] = (this_bounds[0] - xMin) / group_width
                    entries[cp]["group_y"] = (this_bounds[1] - yMin) / group_height

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
    project_root = Path(__file__).resolve().parents[2]

    nf_path = sys.argv[1]

    nerd_font = TTFont(nf_path)

    patcher_path = project_root / "vendor" / "nerd-fonts" / "font-patcher.py"
    source = patcher_path.read_text(encoding="utf-8")
    patch_set = extract_patch_set_values(source)

    out_path = project_root / "src" / "font" / "nerd_font_attributes.zig"

    with out_path.open("w", encoding="utf-8") as f:
        f.write("""//! This is a generated file, produced by nerd_font_codegen.py
//! DO NOT EDIT BY HAND!
//!
//! This file provides info extracted from the nerd fonts patcher script,
//! specifying the scaling/positioning attributes of various glyphs.

const Constraint = @import("face.zig").RenderOptions.Constraint;

/// Get the a constraints for the provided codepoint.
pub fn getConstraint(cp: u21) ?Constraint {
    return switch (cp) {
""")
        f.write(generate_zig_switch_arms(patch_set, nerd_font))
        f.write("\n        else => null,\n    };\n}\n")
