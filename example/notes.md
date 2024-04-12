
Had to add this to build.zig temporarily to find where zig-js was being copied to:
```
    std.debug.print("PATH!!!! {s}\n", .{js_dep.path("").getPath(b)});
```

Then I had to copy that into package.json and npm install.
Had to install parcel as a global dep (`npm install -g parcel`)
