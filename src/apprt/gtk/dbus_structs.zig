const c = @import("c.zig");

pub var gnome_shell_search_provider = c.GDBusInterfaceInfo{
    .ref_count = -1,
    .name = @constCast("org.gnome.Shell.SearchProvider2"),
    .methods = @constCast(
        &[_:null]?*c.GDBusMethodInfo{
            @constCast(
                &.{
                    .ref_count = -1,
                    .name = @constCast("GetInitialResultSet"),
                    .in_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("terms"),
                                    .signature = @constCast("as"),
                                },
                            ),
                        },
                    ),
                    .out_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("results"),
                                    .signature = @constCast("as"),
                                },
                            ),
                        },
                    ),
                    .annotations = null,
                },
            ),
            @constCast(
                &.{
                    .ref_count = -1,
                    .name = @constCast("GetSubsearchResultSet"),
                    .in_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("previous_results"),
                                    .signature = @constCast("as"),
                                },
                            ),
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("terms"),
                                    .signature = @constCast("as"),
                                },
                            ),
                        },
                    ),
                    .out_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("results"),
                                    .signature = @constCast("as"),
                                },
                            ),
                        },
                    ),
                    .annotations = null,
                },
            ),
            @constCast(
                &.{
                    .ref_count = -1,
                    .name = @constCast("GetResultMetas"),
                    .in_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("identifiers"),
                                    .signature = @constCast("as"),
                                },
                            ),
                        },
                    ),
                    .out_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("metas"),
                                    .signature = @constCast("aa{sv}"),
                                },
                            ),
                        },
                    ),
                    .annotations = null,
                },
            ),
            @constCast(
                &.{
                    .ref_count = -1,
                    .name = @constCast("ActivateResult"),
                    .in_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("identifier"),
                                    .signature = @constCast("s"),
                                },
                            ),
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("terms"),
                                    .signature = @constCast("as"),
                                },
                            ),
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("timestamp"),
                                    .signature = @constCast("u"),
                                },
                            ),
                        },
                    ),
                    .out_args = null,
                    .annotations = null,
                },
            ),
            @constCast(
                &.{
                    .ref_count = -1,
                    .name = @constCast("LaunchSearch"),
                    .in_args = @constCast(
                        &[_:null]?*c.GDBusArgInfo{
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("terms"),
                                    .signature = @constCast("as"),
                                },
                            ),
                            @constCast(
                                &.{
                                    .ref_count = -1,
                                    .name = @constCast("timestamp"),
                                    .signature = @constCast("u"),
                                },
                            ),
                        },
                    ),
                    .out_args = null,
                    .annotations = null,
                },
            ),
        },
    ),
    .signals = null,
    .properties = null,
    .annotations = null,
};
