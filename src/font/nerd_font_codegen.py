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
from fontTools.ttLib import TTFont, TTLibError
from fontTools.pens.boundsPen import BoundsPen
from collections import defaultdict
from contextlib import suppress
from pathlib import Path
from types import SimpleNamespace
from typing import Literal, TypedDict, cast
from urllib.request import urlretrieve

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
    Filename: str
    Exact: bool
    SymStart: int
    SymEnd: int
    SrcStart: int | None
    ScaleRules: PatchSetScaleRules | None
    Attributes: PatchSetAttributes


class PatchSetExtractor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.symbol_table: dict[str, ast.expr] = {}
        self.patch_set_values: list[PatchSet] = []
        self.nf_version: str = ""

    def visit_Assign(self, node):
        if (
            node.col_offset == 0  # top-level assignment
            and len(node.targets) == 1  # no funny destructuring business
            and isinstance(node.targets[0], ast.Name)  # no setitem et cetera
            and node.targets[0].id == "version"  # it's the version string!
        ):
            self.nf_version = ast.literal_eval(node.value)
        else:
            return self.generic_visit(node)

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
        for key_node, value_node in zip(dict_node.keys, dict_node.values):
            if isinstance(key_node, ast.Constant):
                if key_node.value == "Enabled":
                    if self.safe_literal_eval(value_node):
                        continue  # This patch set is enabled, continue to next key
                    else:
                        return  # This patch set is disabled, skip
                key = ast.literal_eval(cast("ast.Constant", key_node))
                entry[key] = self.resolve_symbol(value_node)
        self.patch_set_values.append(cast("PatchSet", entry))


def extract_patch_set_values(source_code: str) -> tuple[list[PatchSet], str]:
    tree = ast.parse(source_code)
    extractor = PatchSetExtractor()
    extractor.visit(tree)
    return extractor.patch_set_values, extractor.nf_version


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
        pad = -overlap / 2
        s += f"            .pad_left = {pad},\n"
        s += f"            .pad_right = {pad},\n"
        # In the nerd fonts patcher, overlap values
        # are capped at 0.01 in the vertical direction.
        v_pad = -min(0.01, overlap) / 2
        s += f"            .pad_top = {v_pad},\n"
        s += f"            .pad_bottom = {v_pad},\n"
    elif y_padding:
        s += f"            .pad_top = {y_padding / 2},\n"
        s += f"            .pad_bottom = {y_padding / 2},\n"

    if xy_ratio > 0:
        s += f"            .max_xy_ratio = {xy_ratio},\n"

    s += "        },"
    return s


def generate_codepoint_tables(
    patch_sets: list[PatchSet],
    nerd_font: TTFont,
    nf_version: str,
) -> dict[str, dict[int, int]]:
    # We may already have the table saved from a previous run.
    if Path("nerd_font_codepoint_tables.py").exists():
        import nerd_font_codepoint_tables

        if nerd_font_codepoint_tables.version == nf_version:
            return nerd_font_codepoint_tables.cp_tables

    cp_tables: dict[str, dict[int, int]] = {}
    cp_nerdfont_used: set[int] = set()
    cmap = nerd_font.getBestCmap()
    for entry in patch_sets:
        patch_set_name = entry["Name"]
        print(f"Info: Extracting codepoint table from patch set '{patch_set_name}'")

        # Extract codepoint map from original font file; download if needed
        source_filename = entry["Filename"]
        target_folder = Path("nerd_font_symbol_fonts")
        target_folder.mkdir(exist_ok=True)
        target_file = target_folder / Path(source_filename).name
        if not target_file.exists():
            print(f"Info: Downloading '{source_filename}'")
            urlretrieve(
                f"https://github.com/ryanoasis/nerd-fonts/raw/refs/tags/v{nf_version}/src/glyphs/{source_filename}",
                target_file,
            )
        try:
            with TTFont(target_file) as patchfont:
                patch_cmap = patchfont.getBestCmap()
        except TTLibError:
            # Not a TTF/OTF font. This is OK if this patch set is exact, so we
            # let if pass. If there's a problem, later checks will catch it.
            patch_cmap = None

        # A glyph's scale rules are specified using its codepoint in
        # the original font, which is sometimes different from its
        # Nerd Font codepoint. If entry["Exact"] is False, the codepoints are
        # mapped according to the following rules:
        # * entry["SymStart"] and entry["SymEnd"] denote the patch set's codepoint
        #   range in the original font.
        # * entry["SrcStart"] is the starting point of the patch set's mapped
        #   codepoint range. It must not be None if entry["Exact"] is False.
        # * The destination codepoint range is packed; that is, while there may be
        #   gaps without glyphs in the original font's codepoint range, there are
        #   none in the Nerd Font range. Hence there is no constant codepoint
        #   offset; instead we must iterate through the range and increment the
        #   destination codepoint every time we encounter a glyph in the original
        #   font.
        # If entry["Exact"] is True, the origin and Nerd Font codepoints are the
        # same, gaps included, and entry["SrcStart"] must be None.
        if entry["Exact"]:
            assert entry["SrcStart"] is None
            cp_nerdfont = 0
        else:
            assert entry["SrcStart"]
            assert patch_cmap is not None
            cp_nerdfont = entry["SrcStart"] - 1

        if patch_set_name not in cp_tables:
            # There are several patch sets with the same name, representing
            # different codepoint ranges within the same original font. Merging
            # these into a single table is OK. However, we need to keep separate
            # tables for the different fonts to correctly deal with cases where
            # they fill in each other's gaps.
            cp_tables[patch_set_name] = {}
        for cp_original in range(entry["SymStart"], entry["SymEnd"] + 1):
            if patch_cmap and cp_original not in patch_cmap:
                continue
            if not entry["Exact"]:
                cp_nerdfont += 1
            else:
                cp_nerdfont = cp_original
            if cp_nerdfont not in cmap:
                raise ValueError(
                    f"Missing codepoint in Symbols Only Font: {hex(cp_nerdfont)} in patch set '{patch_set_name}'"
                )
            elif cp_nerdfont in cp_nerdfont_used:
                raise ValueError(
                    f"Overlap for codepoint {hex(cp_nerdfont)} in patch set '{patch_set_name}'"
                )
            cp_tables[patch_set_name][cp_original] = cp_nerdfont
            cp_nerdfont_used.add(cp_nerdfont)

    # Store the table and corresponding Nerd Fonts version together in a module.
    with open("nerd_font_codepoint_tables.py", "w") as f:
        print(
            """#! This is a generated file, produced by nerd_font_codegen.py
#! DO NOT EDIT BY HAND!
#!
#! This file specifies the mapping of codepoints in the original symbol
#! fonts to codepoints in a patched Nerd Font. This is extracted from
#! the nerd fonts patcher script and the symbol font files.""",
            file=f,
        )
        print(f'version = "{nf_version}"', file=f)
        print("cp_tables = {", file=f)
        for name, table in cp_tables.items():
            print(f'    "{name}": {{', file=f)
            for key, value in table.items():
                print(f"        {hex(key)}: {hex(value)},", file=f)
            print("    },", file=f)
        print("}", file=f)

    return cp_tables


def generate_zig_switch_arms(
    patch_sets: list[PatchSet],
    nerd_font: TTFont,
    nf_version: str,
) -> str:
    cmap = nerd_font.getBestCmap()
    glyphs = nerd_font.getGlyphSet()
    cp_tables = generate_codepoint_tables(patch_sets, nerd_font, nf_version)

    entries: dict[int, PatchSetAttributeEntry] = {}
    for entry in patch_sets:
        patch_set_name = entry["Name"]
        print(f"Info: Extracting rules from patch set '{patch_set_name}'")

        attributes = entry["Attributes"]
        patch_set_entries: dict[int, PatchSetAttributeEntry] = {}

        cp_table = cp_tables[patch_set_name]
        for cp_original in range(entry["SymStart"], entry["SymEnd"] + 1):
            if cp_original not in cp_table:
                continue
            cp_nerdfont = cp_table[cp_original]
            if cp_nerdfont in entries:
                raise ValueError(
                    f"Overlap for codepoint {hex(cp_nerdfont)} in patch set '{patch_set_name}'"
                )
            if cp_original in attributes:
                patch_set_entries[cp_nerdfont] = attributes[cp_original].copy()
            else:
                patch_set_entries[cp_nerdfont] = attributes["default"].copy()

        if entry["ScaleRules"] is not None:
            for group in entry["ScaleRules"]["ScaleGroups"]:
                xMin = math.inf
                yMin = math.inf
                xMax = -math.inf
                yMax = -math.inf
                individual_bounds: dict[int, tuple[int, int, int, int]] = {}
                individual_advances: set[float] = set()
                for cp_original in group:
                    if cp_original not in cp_table:
                        # There is one special case where a scale group includes
                        # a glyph from the original font that's not in any patch
                        # set, and hence not in the Symbols Only font. The point
                        # of this glyph is to add extra vertical padding to a
                        # stretched (^xy) scale group, which means that its
                        # scaled and aligned position would span the line height
                        # plus overlap. Thus, we can use any other stretched
                        # glyph with overlap as stand-in to get the vertical
                        # bounds, such as as 0xE0B0 (powerline left hard
                        # divider). We don't worry about the horizontal bounds,
                        # as they by design should not affect the group's
                        # bounding box.
                        if (
                            patch_set_name == "Progress Indicators"
                            and cp_original == 0xEDFF
                        ):
                            glyph = glyphs[cmap[0xE0B0]]
                            bounds = BoundsPen(glyphSet=glyphs)
                            glyph.draw(bounds)
                            yMin = min(bounds.bounds[1], yMin)
                            yMax = max(bounds.bounds[3], yMax)
                        else:
                            # Other cases are due to lazily specified scale
                            # groups with gaps in the codepoint range.
                            print(
                                f"Info: Skipping scale group codepoint {hex(cp_original)}, which does not exist in patch set '{patch_set_name}'"
                            )
                        continue

                    cp_nerdfont = cp_table[cp_original]
                    glyph = glyphs[cmap[cp_nerdfont]]
                    individual_advances.add(glyph.width)
                    bounds = BoundsPen(glyphSet=glyphs)
                    glyph.draw(bounds)
                    individual_bounds[cp_nerdfont] = bounds.bounds
                    xMin = min(bounds.bounds[0], xMin)
                    yMin = min(bounds.bounds[1], yMin)
                    xMax = max(bounds.bounds[2], xMax)
                    yMax = max(bounds.bounds[3], yMax)
                group_width = xMax - xMin
                group_height = yMax - yMin
                group_is_monospace = (len(individual_bounds) > 1) and (
                    len(individual_advances) == 1
                )
                for cp_original in group:
                    if cp_original not in cp_table:
                        continue
                    cp_nerdfont = cp_table[cp_original]
                    if (
                        # Scale groups may cut across patch sets, but we're only
                        # updating a single patch set at a time, so we skip
                        # codepoints not in it.
                        cp_nerdfont not in patch_set_entries
                        # Codepoints may contribute to the bounding box of multiple groups,
                        # but should be scaled according to the first group they are found
                        # in. Hence, to avoid overwriting, we need to skip codepoints that
                        # have already been assigned a scale group.
                        or "relative_height" in patch_set_entries[cp_nerdfont]
                    ):
                        continue
                    this_bounds = individual_bounds[cp_nerdfont]
                    this_height = this_bounds[3] - this_bounds[1]
                    patch_set_entries[cp_nerdfont]["relative_height"] = (
                        this_height / group_height
                    )
                    patch_set_entries[cp_nerdfont]["relative_y"] = (
                        this_bounds[1] - yMin
                    ) / group_height
                    # Horizontal alignment should only be grouped if the group is monospace,
                    # that is, if all glyphs in the group have the same advance width.
                    if group_is_monospace:
                        this_width = this_bounds[2] - this_bounds[0]
                        patch_set_entries[cp_nerdfont]["relative_width"] = (
                            this_width / group_width
                        )
                        patch_set_entries[cp_nerdfont]["relative_x"] = (
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
    patch_set, nf_version = extract_patch_set_values(source)

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
        f.write(generate_zig_switch_arms(patch_set, nerd_font, nf_version))
        f.write("\n        else => null,\n    };\n}\n")
