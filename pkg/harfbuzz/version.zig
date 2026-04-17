const std = @import("std");
const c = @import("c");

pub const Version = struct {
    major: u32,
    minor: u32,
    micro: u32,
};

/// Returns library version as three integer components.
pub fn version() Version {
    var major: c_uint = 0;
    var minor: c_uint = 0;
    var micro: c_uint = 0;
    c.hb_version(&major, &minor, &micro);
    return .{ .major = major, .minor = minor, .micro = micro };
}

/// Tests the library version against a minimum value, as three integer components.
pub fn versionAtLeast(vsn: Version) bool {
    return c.hb_version_atleast(
        vsn.major,
        vsn.minor,
        vsn.micro,
    ) > 0;
}

/// Returns library version as a string with three components.
pub fn versionString() [:0]const u8 {
    const res = c.hb_version_string();
    return std.mem.sliceTo(res, 0);
}

test {
    const testing = std.testing;

    // Should be able to get the version
    const vsn = version();
    try testing.expect(vsn.major > 0);

    // Should be at least version 1
    try testing.expect(versionAtLeast(.{
        .major = 1,
        .minor = 0,
        .micro = 0,
    }));
}
