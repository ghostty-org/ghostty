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
record CRC32C values and cross-record invariants that portable Kaitai
expressions cannot represent.
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


def all_snapshot_records(snapshot: Any) -> list[Any]:
    """Return complete-snapshot records in wire order."""
    records = [snapshot.terminal]
    for sequence in snapshot.screens:
        records.append(sequence.screen)
        records.extend(sequence.pages)
    records.append(snapshot.continuation)
    records.append(snapshot.ready)
    for sequence in snapshot.histories:
        records.append(sequence.history)
        records.extend(sequence.pages)
    records.append(snapshot.finish)
    return records


def validate_complete_snapshot(snapshot: Any, data: bytes) -> None:
    """Validate ordering relationships, record CRCs, and markers."""
    screen_keys = [
        sequence.screen.payload.header.key for sequence in snapshot.screens
    ]
    history_keys = [
        sequence.history.payload.key for sequence in snapshot.histories
    ]
    if len(set(screen_keys)) != len(screen_keys):
        raise ValueError("complete snapshot contains a duplicate SCREEN key")
    if len(set(history_keys)) != len(history_keys):
        raise ValueError("complete snapshot contains a duplicate HISTORY key")
    if set(screen_keys) != set(history_keys):
        raise ValueError("SCREEN and HISTORY keys do not match")

    terminal_header = snapshot.terminal.payload.header
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
        sequence.screen.payload.header.key: sequence
        for sequence in snapshot.screens
    }
    for sequence in snapshot.screens:
        header = sequence.screen.payload.header
        if (
            header.cursor_x >= terminal_header.columns
            or header.cursor_y >= terminal_header.rows
            or (
                header.cursor_flags.pending_wrap
                and header.cursor_x != terminal_header.columns - 1
            )
        ):
            raise ValueError(f"SCREEN key {header.key}: invalid cursor position")

    for sequence in snapshot.histories:
        payload = sequence.history.payload
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
        if history_rows != screen.screen.payload.header.history_rows:
            raise ValueError(
                f"SCREEN key {payload.key}: history_rows "
                f"{screen.screen.payload.header.history_rows} "
                f"does not match {history_rows}"
            )

    for record in all_snapshot_records(snapshot):
        if not hasattr(record, "payload"):
            continue
        payload = record.payload
        if not hasattr(payload, "styles"):
            continue
        style_ids = [entry.encoded_id for entry in payload.styles]
        hyperlink_ids = [entry.encoded_id for entry in payload.hyperlinks]
        if len(set(style_ids)) != len(style_ids):
            raise ValueError("PAGE contains a duplicate style ID")
        if len(set(hyperlink_ids)) != len(hyperlink_ids):
            raise ValueError("PAGE contains a duplicate hyperlink ID")

    offset = SNAPSHOT_ENVELOPE_SIZE
    for record in all_snapshot_records(snapshot):
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
