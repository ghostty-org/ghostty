#!/usr/bin/env python3
"""OMG's remote command entry point. Protocol v1; no background process."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import shutil
import sys
import time
import uuid

LIMIT = 1048576


def private_directory(path):
    # Validate each managed parent before following it to the next child.
    if not path.parent.exists():
        private_directory(path.parent)
    parent_info = path.parent.lstat()
    if not stat.S_ISDIR(parent_info.st_mode):
        raise ValueError("Unsafe OMG remote parent directory")
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("Unsafe OMG remote directory")
    path.chmod(0o700)
    return path


def root():
    override = os.environ.get("OMG_REMOTE_ROOT")
    path = Path(override) if override else Path.home() / ".local/share/oh-my-ghostty/remote"
    if not path.is_absolute():
        raise ValueError("OMG remote directory must be absolute")
    return private_directory(path)


def session_directory(session):
    key = hashlib.sha256(session.encode()).hexdigest()
    sessions = private_directory(root() / "sessions")
    return private_directory(sessions / key)


def write_private(path, content):
    temporary = path.with_name(str(uuid.uuid4()) + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path):
    with path.open("rb") as stream:
        data = stream.read(8193)
    if len(data) > 8192:
        raise ValueError("Invalid remote request")
    return json.loads(data)


def main(arguments):
    if len(arguments) == 2 and arguments[0] == "exec":
        # Host-owned Git/files/inventory/Hook tasks retain their own protocols,
        # limits and stdin, but share OMG's remote process entry point.
        os.execv("/bin/sh", ["sh", "-c", arguments[1]])
    command, session, *rest = arguments
    if command == "install":
        executable = root() / "omg"
        # The SSH bootstrap supplies the exact bundled source when installing.
        write_private(executable, Path(__file__).read_bytes())
        executable.chmod(0o700)
        print(str(executable))
        return
    directory = session_directory(session)
    if command == "session-start":
        # Bound abandoned state after disconnects; active requests expire in seconds.
        cutoff = time.time() - 7 * 86400
        for old in directory.parent.iterdir():
            if old != directory and not old.is_symlink() and old.is_dir() and old.stat().st_mtime < cutoff:
                shutil.rmtree(old)
        write_private(directory / "session.json", json.dumps({
            "protocol": 1, "editor": rest[0] if rest else "nano",
            "created": time.time(), "tty": os.ttyname(0),
        }).encode())
        editor = directory / "editor"
        script = "#!/bin/sh\nexec python3 " + shlex.quote(str(root() / "omg"))
        script += " editor " + shlex.quote(session) + ' "$@"\n'
        write_private(editor, script.encode())
        editor.chmod(0o700)
        print(str(editor))
        return
    if command == "session-end":
        for path in directory.iterdir():
            if path.is_file() and not path.is_symlink():
                path.unlink()
        directory.rmdir()
        return
    metadata = read_json(directory / "session.json")
    if metadata.get("protocol") != 1:
        raise ValueError("Unsupported OMG remote protocol")
    if command == "draft-begin":
        identifier = str(uuid.UUID(rest[0])).upper()
        # Bind requests to the live SSH pane's TTY, not merely its host.
        if metadata["tty"] != rest[1]:
            raise ValueError("Remote session TTY changed")
        if len(rest) > 2 and metadata.get("runtime_generation") != rest[2]:
            raise ValueError("Remote session generation changed")
        write_private(directory / "request.json", json.dumps({
            "id": identifier, "expires": time.time() + 8,
            "generation": metadata.get("runtime_generation"),
        }).encode())
        print("OMG_REMOTE_READY_V1")
    elif command == "draft-read":
        identifier = str(uuid.UUID(rest[0])).upper()
        request = read_json(directory / "request.json")
        if request.get("generation") != metadata.get("runtime_generation"):
            raise ValueError("Remote session generation changed")
        response = directory / (identifier + ".response")
        deadline = time.monotonic() + 5
        while not response.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if request.get("generation") != read_json(directory / "session.json").get("runtime_generation"):
            raise ValueError("Remote session generation changed")
        with response.open("rb") as stream:
            data = stream.read(LIMIT + 1)
        validate(data)
        print("OMG_REMOTE_DRAFT_V1")
        sys.stdout.flush()
        sys.stdout.buffer.write(data)
    elif command == "draft-finish":
        identifier = str(uuid.UUID(rest[0])).upper()
        try:
            request = read_json(directory / "request.json")
            if request["id"] == identifier:
                (directory / "request.json").unlink(missing_ok=True)
        except FileNotFoundError:
            pass
        (directory / (identifier + ".response")).unlink(missing_ok=True)
    elif command == "editor":
        try:
            request = read_json(directory / "request.json")
            identifier = str(uuid.UUID(request["id"])).upper()
            active = time.time() < float(request["expires"]) and request.get("generation") == metadata.get("runtime_generation")
        except (OSError, ValueError, KeyError, TypeError):
            active = False
        if not active:
            os.execv("/bin/sh", ["sh", "-c", "exec " + metadata["editor"] + ' "$@"',
                                 "omg-editor", *rest])
        if len(rest) != 1:
            raise ValueError("Expected one editor file")
        with open(rest[0], "rb") as stream:
            data = stream.read(LIMIT + 1)
        validate(data)
        write_private(directory / (identifier + ".response"), data)
    else:
        raise ValueError("Unknown OMG remote command")


def validate(data):
    if len(data) > LIMIT or b"\0" in data:
        raise ValueError("Invalid draft or draft exceeds 1 MiB")
    data.decode("utf-8")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as error:
        print("OMG remote: " + str(error), file=sys.stderr)
        sys.exit(1)
