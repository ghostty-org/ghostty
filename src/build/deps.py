import json
import pathlib
import subprocess
import tempfile
import urllib.parse
import urllib.request


def clone(deps: pathlib.Path, name: str, url: urllib.parse.ParseResult) -> pathlib.Path:
    repo = urllib.parse.ParseResult(
        scheme=url.scheme.removeprefix("git+"),
        netloc=url.netloc,
        path=url.path,
        params="",
        query="",
        fragment="",
    )
    file = deps / f"{name}-{url.fragment}.tar.gz"
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = pathlib.Path(tmp)
        archivedir = tmpdir / f"{name}-{url.fragment}"
        archivedir.mkdir()
        subprocess.run(
            ["git", "init"],
            cwd=str(archivedir),
            check=True,
        )
        subprocess.run(
            ["git", "remote", "add", "origin", repo.geturl()],
            cwd=str(archivedir),
            check=True,
        )
        subprocess.run(
            ["git", "fetch", "origin", "--depth=1", url.fragment],
            cwd=str(archivedir),
            check=True,
        )
        subprocess.run(
            ["git", "checkout", "FETCH_HEAD"],
            cwd=str(archivedir),
            check=True,
        )
        subprocess.run(
            [
                "tar",
                "--create",
                "--file",
                str(file.resolve()),
                "--exclude",
                ".git",
                f"{name}-{url.fragment}",
            ],
            cwd=str(tmpdir),
            check=True,
        )
    return file


def main() -> None:
    deps = pathlib.Path("deps")
    deps.mkdir(exist_ok=True)
    build = json.load(open("build.zig.zon2json-lock"))
    for data in build.values():
        if "url" not in data:
            continue
        url = urllib.parse.urlparse(data["url"])
        if url.scheme.startswith("git+"):
            file = clone(deps, data["name"], url)
            print(f"{data["url"]} -> {file}")
        else:
            path = pathlib.Path(url.path)
            basename = path.parts[-1]
            if not basename.startswith(f"{data["name"]}-"):
                file = deps / f"{data["name"]}-{basename}"
            else:
                file = deps / basename
            req = urllib.request.Request(
                data["url"], headers={"User-Agent": "ghostty-downloader/1.0"}
            )
            with urllib.request.urlopen(req) as response:
                body = response.read()
                file.write_bytes(body)
            print(f"{data["url"]} -> {file}")


if __name__ == "__main__":
    main()
