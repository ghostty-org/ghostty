import json
import pathlib
import urllib.parse
import urllib.request


def main() -> None:
    deps = pathlib.Path("deps")
    deps.mkdir(exist_ok=True)
    build = json.load(open("build.zig.zon2json-lock"))
    for data in build.values():
        if "url" not in data:
            continue
        url = urllib.parse.urlparse(data["url"])
        if url.scheme.startswith("git+"):
            continue
        path = pathlib.Path(url.path)
        basename = path.parts[-1]
        if not basename.startswith(f"{data["name"]}-"):
            file = deps / f"{data["name"]}-{basename}"
        else:
            file = deps / basename
        req = urllib.request.Request(data["url"], headers={"User-Agent": "ghostty/1.0"})
        with urllib.request.urlopen(req) as response:
            body = response.read()
            file.write_bytes(body)
        print(f"{data["url"]} -> https://deps.files.ghostty.org/{file.parts[-1]}")


if __name__ == "__main__":
    main()
