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

    relative_x: float
    relative_y: float
    relative_width: float
    relative_height: float


class PatchSet(TypedDict):
    Name: str
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
                    {"box_enabled": False, "box_keep": False},
                    {
                        "self": SimpleNamespace(
                            args=SimpleNamespace(
                                careful=False,
                                custom=False,
                                fontawesome=True,
                                fontawesomeextension=True,
                                fontlogos=True,
                                octicons=True,
                                codicons=True,
                                powersymbols=True,
                                pomicons=True,
                                powerline=True,
                                powerlineextra=True,
                                material=True,
                                weather=True,
                            )
                        ),
                    },
                )
            msg = f"<cannot eval: {type(node).__name__}>"
            raise ValueError(msg) from None

    def process_patch_entry(self, dict_node: ast.Dict) -> None:
        entry = {}
        disallowed_key_nodes = frozenset({"Filename", "Exact"})
        for key_node, value_node in zip(dict_node.keys, dict_node.values):
            if (
                isinstance(key_node, ast.Constant)
                and key_node.value not in disallowed_key_nodes
            ):
                if key_node.value == "Enabled":
                    if self.safe_literal_eval(value_node):
                        continue  # This patch set is enabled, continue to next key
                    else:
                        return  # This patch set is disabled, skip
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
        "c": ".center1",  # font-patcher specific centering rule, see face.zig
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
        float(attr.get("relative_x", 0.0)),
        float(attr.get("relative_y", 0.0)),
        float(attr.get("relative_width", 1.0)),
        float(attr.get("relative_height", 1.0)),
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

    relative_x = attr.get("relative_x", 0.0)
    relative_y = attr.get("relative_y", 0.0)
    relative_width = attr.get("relative_width", 1.0)
    relative_height = attr.get("relative_height", 1.0)

    overlap = params.get("overlap", 0.0)
    xy_ratio = params.get("xy-ratio", -1.0)
    y_padding = params.get("ypadding", 0.0)

    ranges = coalesce_codepoints_to_ranges(codepoints)
    keys = "\n".join(
        f"        {start:#x}...{end:#x}," if start != end else f"        {start:#x},"
        for start, end in ranges
    )

    s = f"{keys}\n        => .{{\n"

    # This maps the font_patcher stretch rules to a Constrain instance
    # NOTE: some comments in font_patcher indicate that only x or y
    # would also be a valid spec, but no icons use it, so we won't
    # support it until we have to.
    if "pa" in stretch:
        if "!" in stretch or overlap:
            s += "            .size = .cover,\n"
        else:
            s += "            .size = .fit_cover1,\n"
    elif "xy" in stretch:
        s += "            .size = .stretch,\n"
    else:
        print(f"Warning: Unknown stretch rule {stretch}")

    # `^` indicates that scaling should use the
    # full cell height, not just the icon height,
    # even when the constraint width is 1
    if "^" not in stretch:
        s += "            .height = .icon,\n"

    # There are two cases where we want to limit the constraint width to 1:
    # - If there's a `1` in the stretch mode string.
    # - If the stretch mode is not `pa` and there's not an explicit `2`.
    if "1" in stretch or ("pa" not in stretch and "2" not in stretch):
        s += "            .max_constraint_width = 1,\n"

    if align is not None:
        s += f"            .align_horizontal = {align},\n"
    if valign is not None:
        s += f"            .align_vertical = {valign},\n"

    if relative_width != 1.0:
        s += f"            .relative_width = {relative_width:.16f},\n"
    if relative_height != 1.0:
        s += f"            .relative_height = {relative_height:.16f},\n"
    if relative_x != 0.0:
        s += f"            .relative_x = {relative_x:.16f},\n"
    if relative_y != 0.0:
        s += f"            .relative_y = {relative_y:.16f},\n"

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
        patch_set_name = entry["Name"]
        print(f"Info: Extracting rules from patch set '{patch_set_name}'")

        attributes = entry["Attributes"]
        patch_set_entries: dict[int, PatchSetAttributeEntry] = {}

        # A glyph's scale rules are specified using its codepoint in
        # the original font, which is sometimes different from its
        # Nerd Font codepoint. In font_patcher, the font to be patched
        # (including the Symbols Only font embedded in Ghostty) is
        # termed the sourceFont, while the original font is the
        # symbolFont. Thus, the offset that maps the scale rule
        # codepoint to the Nerd Font codepoint is SrcStart - SymStart.
        cp_offset = entry["SrcStart"] - entry["SymStart"] if entry["SrcStart"] else 0
        for cp_rule in range(entry["SymStart"], entry["SymEnd"] + 1):
            cp_font = cp_rule + cp_offset
            if cp_font not in cmap:
                print(f"Info: Skipping missing codepoint {hex(cp_font)}")
                continue
            elif cp_font in entries:
                # Patch sets sometimes have overlapping codepoint ranges.
                # Sometimes a later set is a smaller set filling in a gap
                # in the range of a larger, preceding set. Sometimes it's
                # the other way around. The best thing we can do is hardcode
                # each case.
                if patch_set_name == "Font Awesome":
                    # The Font Awesome range has a gap matching the
                    # prededing Progress Indicators range.
                    print(f"Info: Not overwriting existing codepoint {hex(cp_font)}")
                    continue
                elif patch_set_name == "Octicons":
                    # The fourth Octicons range overlaps with the first.
                    print(f"Info: Overwriting existing codepoint {hex(cp_font)}")
                else:
                    raise ValueError(
                        f"Unknown case of overlap for codepoint {hex(cp_font)} in patch set '{patch_set_name}'"
                    )
            if cp_rule in attributes:
                patch_set_entries[cp_font] = attributes[cp_rule].copy()
            else:
                patch_set_entries[cp_font] = attributes["default"].copy()

        if entry["ScaleRules"] is not None:
            if "ScaleGroups" not in entry["ScaleRules"]:
                raise ValueError(
                    f"Scale rule format {entry['ScaleRules']} not implemented."
                )
            for group in entry["ScaleRules"]["ScaleGroups"]:
                xMin = math.inf
                yMin = math.inf
                xMax = -math.inf
                yMax = -math.inf
                individual_bounds: dict[int, tuple[int, int, int, int]] = {}
                individual_advances: set[float] = set()
                for cp_rule in group:
                    cp_font = cp_rule + cp_offset
                    if cp_font not in cmap:
                        continue
                    glyph = glyphs[cmap[cp_font]]
                    individual_advances.add(glyph.width)
                    bounds = BoundsPen(glyphSet=glyphs)
                    glyph.draw(bounds)
                    individual_bounds[cp_font] = bounds.bounds
                    xMin = min(bounds.bounds[0], xMin)
                    yMin = min(bounds.bounds[1], yMin)
                    xMax = max(bounds.bounds[2], xMax)
                    yMax = max(bounds.bounds[3], yMax)
                group_width = xMax - xMin
                group_height = yMax - yMin
                group_is_monospace = (len(individual_bounds) > 1) and (
                    len(individual_advances) == 1
                )
                for cp_rule in group:
                    cp_font = cp_rule + cp_offset
                    if (
                        cp_font not in cmap
                        or cp_font not in patch_set_entries
                        # Codepoints may contribute to the bounding box of multiple groups,
                        # but should be scaled according to the first group they are found
                        # in. Hence, to avoid overwriting, we need to skip codepoints that
                        # have already been assigned a scale group.
                        or "relative_height" in patch_set_entries[cp_font]
                    ):
                        continue
                    this_bounds = individual_bounds[cp_font]
                    this_height = this_bounds[3] - this_bounds[1]
                    patch_set_entries[cp_font]["relative_height"] = (
                        this_height / group_height
                    )
                    patch_set_entries[cp_font]["relative_y"] = (
                        this_bounds[1] - yMin
                    ) / group_height
                    # Horizontal alignment should only be grouped if the group is monospace,
                    # that is, if all glyphs in the group have the same advance width.
                    if group_is_monospace:
                        this_width = this_bounds[2] - this_bounds[0]
                        patch_set_entries[cp_font]["relative_width"] = (
                            this_width / group_width
                        )
                        patch_set_entries[cp_font]["relative_x"] = (
                            this_bounds[0] - xMin
                        ) / group_width
        entries |= patch_set_entries

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

/// Get the constraints for the provided codepoint.
pub fn getConstraint(cp: u21) ?Constraint {
    return switch (cp) {
""")
        f.write(generate_zig_switch_arms(patch_set, nerd_font))
        f.write("\n        else => null,\n    };\n}\n")
