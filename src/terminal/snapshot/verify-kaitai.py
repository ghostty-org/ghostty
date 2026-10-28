#!/usr/bin/env python3
"""Compile the snapshot Kaitai schema and parse every checked-in fixture.

Run this from a Ghostty development shell:

    src/terminal/snapshot/verify-kaitai.py

To turn an annotated fixture into a binary suitable for the Kaitai Web IDE:

    src/terminal/snapshot/verify-kaitai.py \
        --write-binary \
        src/terminal/snapshot/testdata/complete-v1.hex \
        /tmp/complete-v1.bin

Then load `snapshot.ksy` and the generated binary into
https://ide.kaitai.io/.

The generated Python parser exists only in a temporary directory. This keeps
snapshot.ksy as the source of truth and ensures this check cannot accidentally
pass against stale generated code. After structural parsing, the script checks
what portable Kaitai expressions cannot represent: every record's CRC32C,
including records with unknown tags, the order, declared counts and screen
keys of the known records, that Kitty graphics image lengths and pins are
consistent with the pages and images they refer to, and that every pixel
payload holds exactly the pixels its image or frame expects.
"""

from __future__ import annotations

import argparse
import importlib
import io
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    from kaitaistruct import KaitaiStream
except ImportError as error:
    raise SystemExit(
        "missing Kaitai verifier dependencies; run this inside "
        "`nix develop`"
    ) from error


SNAPSHOT_DIR = Path(__file__).resolve().parent
SCHEMA_PATH = SNAPSHOT_DIR / "snapshot.ksy"
TESTDATA_DIR = SNAPSHOT_DIR / "testdata"
SNAPSHOT_ENVELOPE_SIZE = 10
RECORD_HEADER_SIZE = struct.calcsize("<HII")


@dataclass(frozen=True)
class Fixture:
    path: Path
    type_name: str
    params: tuple[object, ...]
    offset: int
    data: bytes


def load_fixture(path: Path) -> Fixture:
    """Load one self-describing annotated hexadecimal fixture."""
    metadata: dict[str, str] = {}
    chunks: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        content, separator, comment = line.partition("#")
        chunks.extend(content.split())

        if not separator:
            continue
        comment = comment.strip()
        if not comment.startswith("Kaitai "):
            continue
        key, colon, value = comment.removeprefix("Kaitai ").partition(":")
        if not colon or key not in {"type", "params", "offset"}:
            raise ValueError(f"{path}: invalid Kaitai metadata: {comment}")
        if key in metadata:
            raise ValueError(f"{path}: duplicate Kaitai {key} metadata")
        metadata[key] = value.strip()

    try:
        data = bytes.fromhex(" ".join(chunks))
    except ValueError as error:
        raise ValueError(f"{path}: invalid annotated hexadecimal") from error

    required = {"type", "params", "offset"}
    if metadata.keys() != required:
        missing = sorted(required - metadata.keys())
        extra = sorted(metadata.keys() - required)
        raise ValueError(
            f"{path}: Kaitai metadata drift: missing={missing}, extra={extra}"
        )
    if not metadata["type"]:
        raise ValueError(f"{path}: empty Kaitai type")

    params: list[object] = []
    for value in metadata["params"].split():
        if value == "true":
            params.append(True)
        elif value == "false":
            params.append(False)
        else:
            try:
                params.append(int(value, 0))
            except ValueError as error:
                raise ValueError(
                    f"{path}: invalid Kaitai parameter {value!r}"
                ) from error

    try:
        offset = int(metadata["offset"], 0)
    except ValueError as error:
        raise ValueError(f"{path}: invalid Kaitai offset") from error
    if offset < 0 or offset > len(data):
        raise ValueError(f"{path}: Kaitai offset is outside the fixture")

    return Fixture(
        path=path,
        type_name=metadata["type"],
        params=tuple(params),
        offset=offset,
        data=data,
    )


def parse_type(
    parser_type: type[Any],
    data: bytes,
    *params: object,
) -> Any:
    """Construct one generated Kaitai type and require exact exhaustion."""
    stream = KaitaiStream(io.BytesIO(data))
    result = parser_type(*params, stream)
    if not stream.is_eof():
        raise ValueError(
            f"{parser_type.__name__} left "
            f"{stream.size() - stream.pos()} trailing bytes"
        )
    return result


def crc32c(data: bytes) -> int:
    """Return CRC32C using the reflected Castagnoli polynomial."""
    result = 0xFFFFFFFF
    for byte in data:
        result ^= byte
        for _ in range(8):
            result = (
                (result >> 1) ^ 0x82F63B78
                if result & 1
                else result >> 1
            )
    return result ^ 0xFFFFFFFF


def validate_record(record: Any, data: bytes, offset: int) -> int:
    """Validate one parsed record's source bytes and CRC32C."""
    payload = getattr(record, "_raw_payload", record.payload)
    header = record.header
    if header.payload_length != len(payload):
        raise ValueError(
            f"record at 0x{offset:x}: declared {header.payload_length} "
            f"payload bytes but parsed {len(payload)}"
        )

    encoded_header = data[offset : offset + RECORD_HEADER_SIZE]
    expected_header = struct.pack(
        "<HII",
        header.tag,
        header.payload_length,
        header.crc32c,
    )
    if encoded_header != expected_header:
        raise ValueError(f"record at 0x{offset:x}: parsed header drift")

    covered = struct.pack("<HI", header.tag, header.payload_length) + payload
    actual_crc = crc32c(covered)
    if header.crc32c != actual_crc:
        raise ValueError(
            f"record at 0x{offset:x}: CRC32C 0x{header.crc32c:08x} "
            f"does not match 0x{actual_crc:08x}"
        )

    return offset + RECORD_HEADER_SIZE + len(payload)


TAG_TERMINAL = 1
TAG_SCREEN = 2
TAG_PAGE = 3
TAG_HISTORY = 4
TAG_READY = 5
TAG_FINISH = 6
TAG_CONTINUATION = 7
TAG_KITTY_IMAGE_STORAGE = 8
TAG_KITTY_IMAGE_PAYLOAD = 9
TAG_KITTY_IMAGE_PAGE_PLACEMENTS = 10
KNOWN_TAGS = {
    *range(TAG_TERMINAL, TAG_CONTINUATION + 1),
    TAG_KITTY_IMAGE_STORAGE,
    TAG_KITTY_IMAGE_PAYLOAD,
    TAG_KITTY_IMAGE_PAGE_PLACEMENTS,
}
KITTY_BPP = {"rgb": 3, "rgba": 4, "gray_alpha": 2, "gray": 1}


@dataclass
class Sequence:
    """A SCREEN or HISTORY record, its PAGE records, and the optional Kitty
    graphics records that belong to it."""

    record: Any
    pages: list[Any]

    # SCREEN only: the KITTY_IMAGE_STORAGE record right after the pages, or
    # None.
    kitty_image_storage: Any | None

    # HISTORY only: the KITTY_IMAGE_PAGE_PLACEMENTS record after each page, or
    # None for a page without one.
    page_placements: list[Any | None]


@dataclass
class Structure:
    """The known records of a complete snapshot, grouped by role."""

    terminal: Any
    screens: list[Sequence]
    continuation: Any

    # The KITTY_IMAGE_PAYLOAD records between READY and FINISH, in order.
    kitty_image_payloads: list[Any]

    histories: list[Sequence]


class KnownRecords:
    """Walk the known records in wire order, skipping unknown ones.

    This mirrors the Zig decoder, which ignores records with unknown tags
    wherever they appear. Their CRC32C values are still checked separately
    by validate_record.
    """

    def __init__(self, snapshot: Any) -> None:
        self.records = [
            record
            for record in snapshot.records
            if record.header.tag in KNOWN_TAGS
        ]
        self.index = 0

        # Once READY is taken, KITTY_IMAGE_PAYLOAD records may come before any
        # other record. take collects them here.
        self.allow_payloads = False
        self.payloads: list[Any] = []

    def peek(self) -> int | None:
        """Return the tag of the next known record, or None at the end."""
        if self.index >= len(self.records):
            return None
        return self.records[self.index].header.tag

    def take(self, tag: int) -> Any:
        """Consume the next known record, which must have this tag. After
        READY, KITTY_IMAGE_PAYLOAD records before it are collected first."""
        while self.allow_payloads and self.peek() == TAG_KITTY_IMAGE_PAYLOAD:
            self.payloads.append(self.records[self.index])
            self.index += 1
        actual = self.peek()
        if actual != tag:
            raise ValueError(f"expected record tag {tag}, found {actual}")
        record = self.records[self.index]
        self.index += 1
        return record

    def take_optional(self, tag: int) -> Any | None:
        """Consume the next known record if it has this tag. A
        KITTY_IMAGE_PAYLOAD in between means the record is absent, which is
        how a payload between a PAGE and its KITTY_IMAGE_PAGE_PLACEMENTS is
        caught."""
        return self.take(tag) if self.peek() == tag else None

    def take_sequence(self, tag: int, page_count: Any) -> Sequence:
        """Consume a SCREEN or HISTORY record, the PAGE records it declares,
        and the optional Kitty graphics records that follow them. page_count
        reads the declared count from the first record."""
        record = self.take(tag)
        pages: list[Any] = []
        page_placements: list[Any | None] = []
        for _ in range(page_count(record)):
            pages.append(self.take(TAG_PAGE))
            page_placements.append(
                self.take_optional(TAG_KITTY_IMAGE_PAGE_PLACEMENTS)
                if tag == TAG_HISTORY
                else None
            )
        kitty_image_storage = (
            self.take_optional(TAG_KITTY_IMAGE_STORAGE)
            if tag == TAG_SCREEN
            else None
        )
        return Sequence(record, pages, kitty_image_storage, page_placements)


def snapshot_structure(snapshot: Any) -> Structure:
    """Group known records by role and validate their order."""
    records = KnownRecords(snapshot)
    terminal = records.take(TAG_TERMINAL)
    screen_count = terminal.payload.header.screen_count

    screens = [
        records.take_sequence(
            TAG_SCREEN,
            lambda record: record.payload.header.page_count,
        )
        for _ in range(screen_count)
    ]
    continuation = records.take(TAG_CONTINUATION)
    records.take(TAG_READY)
    records.allow_payloads = True

    histories = [
        records.take_sequence(
            TAG_HISTORY,
            lambda record: record.payload.page_count,
        )
        for _ in range(screen_count)
    ]
    records.take(TAG_FINISH)
    if records.peek() is not None:
        raise ValueError("records follow FINISH")

    return Structure(
        terminal=terminal,
        screens=screens,
        continuation=continuation,
        kitty_image_payloads=records.payloads,
        histories=histories,
    )


def validate_kitty_pin(pin: Any, page: Any, label: str) -> None:
    """Require a placement pin to name a cell of its page."""
    header = page.payload.header
    if pin.y >= header.rows or pin.x >= header.columns:
        raise ValueError(f"{label}: pin outside its page")


def validate_kitty_image_payload(
    payload: Any,
    images_by_key: dict[Any, dict[int, Any]],
) -> None:
    """Require a KITTY_IMAGE_PAYLOAD to name a declared screen and an image or
    frame on it, and to decode to exactly that length."""
    images = images_by_key.get(payload.key)
    if images is None:
        raise ValueError(
            f"KITTY_IMAGE_PAYLOAD names undeclared screen {payload.key}"
        )
    image = images.get(payload.image_id)
    if image is None:
        raise ValueError(f"payload for unknown image {payload.image_id}")
    if payload.frame == 1:
        expected = image.data_length
    else:
        animation = getattr(image, "animation", None)
        frames = animation.frames if animation is not None else []
        if payload.frame - 2 >= len(frames):
            raise ValueError("payload for a missing animation frame")
        expected = frames[payload.frame - 2].data_length
    if payload.len_data != expected:
        raise ValueError("payload len_data mismatch")


def validate_kitty(structure: Structure) -> None:
    """Validate the Kitty graphics records: screen keys, image and frame
    lengths, that every pin names a cell of its page, and that every pixel
    payload belongs to an image and has its expected length."""
    images_by_key: dict[Any, dict[int, Any]] = {}
    for screen in structure.screens:
        key = screen.record.payload.header.key
        images_by_key[key] = {}
        storage = screen.kitty_image_storage
        if storage is None:
            continue
        payload = storage.payload
        if payload.key != key:
            raise ValueError("KITTY_IMAGE_STORAGE key differs from its SCREEN")
        images_by_key[key] = {image.id: image for image in payload.images}

        for image in payload.images:
            if image.format.name not in KITTY_BPP:
                raise ValueError(f"image {image.id}: stored as {image.format}")
            expected = image.width * image.height * KITTY_BPP[image.format.name]
            if image.data_length != expected:
                raise ValueError(f"image {image.id}: data_length mismatch")
            animation = getattr(image, "animation", None)
            if animation is not None:
                frame_length = image.width * image.height * 4
                for frame in animation.frames:
                    if frame.data_length != frame_length:
                        raise ValueError(
                            f"image {image.id}: frame data_length mismatch"
                        )

        for placement in payload.placements:
            pin = getattr(placement, "pin", None)
            if pin is None:
                continue
            if pin.page >= len(screen.pages):
                raise ValueError(
                    "KITTY_IMAGE_STORAGE pin names a missing page"
                )
            validate_kitty_pin(
                pin,
                screen.pages[pin.page],
                "KITTY_IMAGE_STORAGE",
            )

    for record in structure.kitty_image_payloads:
        validate_kitty_image_payload(record.payload, images_by_key)

    for sequence in structure.histories:
        key = sequence.record.payload.key
        for page, placements in zip(sequence.pages, sequence.page_placements):
            if placements is None:
                continue
            if placements.payload.key != key:
                raise ValueError(
                    "KITTY_IMAGE_PAGE_PLACEMENTS key differs from HISTORY"
                )
            for placement in placements.payload.placements:
                if placement.location.name == "virtual":
                    raise ValueError("virtual placement in history")
                pin = getattr(placement, "pin", None)
                if pin is not None:
                    validate_kitty_pin(
                        pin,
                        page,
                        "KITTY_IMAGE_PAGE_PLACEMENTS",
                    )


def validate_complete_snapshot(snapshot: Any, data: bytes) -> None:
    """Validate ordering relationships, record CRCs, and markers."""
    structure = snapshot_structure(snapshot)
    screen_keys = [
        sequence.record.payload.header.key for sequence in structure.screens
    ]
    history_keys = [
        sequence.record.payload.key for sequence in structure.histories
    ]
    if len(set(screen_keys)) != len(screen_keys):
        raise ValueError("complete snapshot contains a duplicate SCREEN key")
    if len(set(history_keys)) != len(history_keys):
        raise ValueError("complete snapshot contains a duplicate HISTORY key")
    if set(screen_keys) != set(history_keys):
        raise ValueError("SCREEN and HISTORY keys do not match")

    terminal_header = structure.terminal.payload.header
    expected_key_values = (
        {0} if terminal_header.screen_count == 1 else {0, 1}
    )
    screen_key_values = {key.value for key in screen_keys}
    if screen_key_values != expected_key_values:
        raise ValueError(
            f"TERMINAL declares screen keys {expected_key_values}, "
            f"but SCREEN records contain {screen_key_values}"
        )

    screens_by_key = {
        sequence.record.payload.header.key: sequence
        for sequence in structure.screens
    }
    for sequence in structure.screens:
        header = sequence.record.payload.header
        if (
            header.cursor_x >= terminal_header.columns
            or header.cursor_y >= terminal_header.rows
            or (
                header.cursor_flags.pending_wrap
                and header.cursor_x != terminal_header.columns - 1
            )
        ):
            raise ValueError(f"SCREEN key {header.key}: invalid cursor position")

    for sequence in structure.histories:
        payload = sequence.record.payload
        screen = screens_by_key[payload.key]
        screen_rows = sum(
            page.payload.header.rows for page in screen.pages
        )
        if screen_rows < terminal_header.rows:
            raise ValueError(
                f"SCREEN key {payload.key}: PAGE rows do not cover "
                "the active area"
            )
        overlap_rows = screen_rows - terminal_header.rows
        history_rows = overlap_rows + sum(
            page.payload.header.rows for page in sequence.pages
        )
        if history_rows != screen.record.payload.header.history_rows:
            raise ValueError(
                f"SCREEN key {payload.key}: history_rows "
                f"{screen.record.payload.header.history_rows} "
                f"does not match {history_rows}"
            )

    validate_kitty(structure)

    for record in snapshot.records:
        payload = record.payload
        if not hasattr(payload, "styles"):
            continue
        style_ids = [entry.encoded_id for entry in payload.styles]
        hyperlink_ids = [entry.encoded_id for entry in payload.hyperlinks]
        if len(set(style_ids)) != len(style_ids):
            raise ValueError("PAGE contains a duplicate style ID")
        if len(set(hyperlink_ids)) != len(hyperlink_ids):
            raise ValueError("PAGE contains a duplicate hyperlink ID")

    # Every record, including unknown ones, is framed and checksummed.
    offset = SNAPSHOT_ENVELOPE_SIZE
    for record in snapshot.records:
        offset = validate_record(record, data, offset)

    if offset != len(data):
        raise ValueError(
            f"complete snapshot accounted for {offset} of {len(data)} bytes"
        )


def compile_schema(output_dir: Path) -> type[Any]:
    """Compile snapshot.ksy and import its temporary Python parser."""
    compiler = shutil.which("kaitai-struct-compiler") or shutil.which("ksc")
    if compiler is None:
        raise SystemExit(
            "kaitai-struct-compiler is not available; run this inside "
            "`nix develop`"
        )

    subprocess.run(
        [
            compiler,
            "--target=python",
            f"--outdir={output_dir}",
            str(SCHEMA_PATH),
        ],
        check=True,
    )

    sys.path.insert(0, str(output_dir))
    try:
        module = importlib.import_module("ghostty_snapshot")
    finally:
        sys.path.pop(0)
    return module.GhosttySnapshot


def resolve_type(parser: type[Any], type_name: str) -> type[Any]:
    """Resolve one KSY snake-case type name on the generated parser."""
    root_type_name = "".join(
        f"_{character.lower()}" if character.isupper() else character
        for character in parser.__name__
    ).lstrip("_")
    if type_name == root_type_name:
        return parser

    class_name = "".join(
        part[:1].upper() + part[1:] for part in type_name.split("_")
    )
    try:
        return getattr(parser, class_name)
    except AttributeError as error:
        raise ValueError(f"snapshot.ksy has no type {type_name!r}") from error


def main() -> int:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument(
        "--write-binary",
        nargs=2,
        metavar=("FIXTURE", "OUTPUT"),
        type=Path,
        help="decode one annotated fixture into a raw binary",
    )
    args = cli.parse_args()

    if args.write_binary:
        fixture_path, output_path = args.write_binary
        fixture = load_fixture(fixture_path)
        output_path.write_bytes(fixture.data)
        print(f"wrote {len(fixture.data)} bytes to {output_path}")
        return 0

    with tempfile.TemporaryDirectory(prefix="ghostty-kaitai-") as temp:
        parser = compile_schema(Path(temp))

        fixture_paths = sorted(TESTDATA_DIR.rglob("*.hex"))
        if not fixture_paths:
            raise ValueError(f"{TESTDATA_DIR}: no snapshot fixtures")

        for path in fixture_paths:
            fixture = load_fixture(path)
            parser_type = resolve_type(parser, fixture.type_name)
            fixture_label = path.relative_to(TESTDATA_DIR)
            try:
                parsed = parse_type(
                    parser_type,
                    fixture.data[fixture.offset:],
                    *fixture.params,
                )
            except Exception as error:
                raise ValueError(
                    f"{fixture_label}: Kaitai parse failed"
                ) from error

            if parser_type is parser:
                if fixture.offset != 0:
                    raise ValueError(
                        f"{fixture_label}: root parser must begin at offset zero"
                    )
                validate_complete_snapshot(parsed, fixture.data)
            elif hasattr(parsed, "_raw_payload"):
                record_end = validate_record(
                    parsed,
                    fixture.data,
                    fixture.offset,
                )
                if record_end != len(fixture.data):
                    raise ValueError(
                        f"{fixture_label}: record has trailing data"
                    )
            print(f"ok {fixture_label}")

    print(f"validated {len(fixture_paths)} snapshot fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

