#!/usr/bin/env python3
"""Validate the ABI manifest exported by a native or WebAssembly library."""

from __future__ import annotations

import argparse
import ctypes
import json
import sys
from pathlib import Path
from typing import Any

try:
    import jsonschema
except ImportError as error:
    raise SystemExit(
        "missing ABI schema verifier dependencies; run this inside "
        "`nix develop`"
    ) from error


def load_native_manifest(path: Path) -> bytes:
    """Call ghostty_type_json in a native shared library."""
    library = ctypes.CDLL(str(path.resolve()))
    type_json = library.ghostty_type_json
    type_json.argtypes = ()
    type_json.restype = ctypes.c_char_p

    result = type_json()
    if result is None:
        raise RuntimeError("ghostty_type_json returned NULL")
    return result


def load_wasm_manifest(path: Path) -> bytes:
    """Call ghostty_type_json and read its result from WebAssembly memory."""
    try:
        import wasmtime
    except ImportError as error:
        raise SystemExit(
            "missing WebAssembly verifier dependencies; run this inside "
            "`nix develop`"
        ) from error

    engine = wasmtime.Engine()
    module = wasmtime.Module.from_file(engine, str(path))
    store = wasmtime.Store(engine)
    instance = wasmtime.Instance(store, module, [])
    exports = instance.exports(store)
    memory = exports["memory"]
    type_json = exports["ghostty_type_json"]

    pointer = type_json(store)
    data = memory.read(store, pointer, memory.data_len(store))
    terminator = data.find(b"\0")
    if terminator < 0:
        raise RuntimeError("ghostty_type_json result is not NUL terminated")
    return bytes(data[:terminator])


def load_manifest(path: Path) -> dict[str, Any]:
    """Execute the public export and decode its JSON result."""
    encoded = (
        load_wasm_manifest(path)
        if path.suffix.lower() == ".wasm"
        else load_native_manifest(path)
    )
    value = json.loads(encoded)
    if not isinstance(value, dict):
        raise ValueError("ghostty_type_json did not return a JSON object")
    return value


def format_path(parts: list[object]) -> str:
    """Format a jsonschema error path for command-line output."""
    return "/" + "/".join(str(part) for part in parts)


def validate(schema_path: Path, library_path: Path) -> None:
    """Validate the schema itself and the manifest returned by the library."""
    schema = json.loads(schema_path.read_bytes())
    validator_type = jsonschema.validators.validator_for(schema)
    validator_type.check_schema(schema)

    manifest = load_manifest(library_path)
    errors = sorted(
        validator_type(schema).iter_errors(manifest),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        for error in errors:
            print(
                f"{format_path(list(error.absolute_path))}: {error.message}",
                file=sys.stderr,
            )
        raise SystemExit(f"ABI manifest failed {schema_path}")

    abi = manifest["abi"]
    print(
        f"validated {abi['target']}-{abi['os']} ABI manifest "
        f"({len(manifest['types'])} types)"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", type=Path)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    validate(args.schema, args.library)


if __name__ == "__main__":
    main()
