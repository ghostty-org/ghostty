//! Test root for the agent IPC surface (`src/apprt/ipc/`).
//!
//! The agent IPC modules live three levels deep and reach `../../App.zig`,
//! `../../Surface.zig`, `../../apprt.zig`, `../../terminal/main.zig`, and
//! `../../input/*`. Zig rejects an import that leaves the module root, so a
//! module rooted at `src/apprt/ipc/` cannot resolve them. This file therefore
//! sits directly in `src/`, alongside the equivalent precedent
//! (`src/main_windows_apprt.zig`), so the whole app runtime stays inside the
//! module and build.zig's `test-agent-ipc` step can give it the same dependency
//! set as the main test root (`src/main.zig`).
//!
//! Why this root exists
//! --------------------
//! `zig build test` does not reach these modules. Every file in
//! `src/apprt/ipc/` has been unit tested against `fake_host.zig` — the
//! in-memory `Host` vtable — but `app_host.zig`, the `Host` implementation
//! backed by the real application runtime, has never been in the build graph.
//! Its own header calls that out: "not yet in the build graph". Until it is
//! compiled, the IPC layer is testable but not live: the protocol, parser,
//! socket server, and pane registry all work against a fake, and nothing has
//! ever type-checked the bridge onto `App`, `CoreSurface`, and the runtime's
//! action system.
//!
//! This root closes exactly that gap and nothing more. It does not start a
//! server, does not build a socket, and does not run the app. It compiles
//! `app_host.zig` alongside its siblings so a type error in the bridge fails
//! here instead of being discovered later by whoever wires it into the runtime.
//!
//! Honest scope — read before trusting a green result
//! ------------------------------------------------
//! `app_host.zig` compiles here, but on this host it is *analyzed shallowly*.
//! Per its own header, only the GTK runtime is `windowed`, and only a windowed
//! build type-checks the vtable bodies that actually call into `App`,
//! `CoreSurface`, and the runtime's action system. Every non-windowed artifact
//! (`.none`, the Windows scaffold, lib, wasm) discards those bodies and returns
//! `error.Unsupported` instead. So:
//!
//!   * a green `zig build test-agent-ipc` proves the file, its imports, and
//!     the signatures of `AppHost` all resolve — not that `pane.create` really
//!     splits a surface;
//!   * the vtable bodies need `zig build test-agent-ipc -Dapp-runtime=gtk`
//!     (and eventually Linux/macOS runtimes) to be fully analyzed.
//!
//! The test below asserts `windowed` is false on this host and states why, so
//! the shallow-compile caveat is recorded in the build output rather than
//! living only in this comment.
//!
//! Run with: `zig build test-agent-ipc`

const std = @import("std");
const build_config = @import("build_config.zig");

/// Mirrors `app_host.windowed` exactly. Only the GTK runtime qualifies today:
/// the Windows runtime is a scaffold (WBS G3) and the lib/wasm artifacts have
/// no windows. `app_host.windowed` is reachable directly; this local alias is
/// for brevity only and is not a divergence-detection mechanism (the alias
/// and the underlying declaration cannot differ — they are the same value).
const app_host = @import("apprt/ipc/app_host.zig");
const windowed: bool = app_host.windowed;

test {
    _ = @import("apprt/ipc/protocol.zig");
    _ = @import("apprt/ipc/auth.zig");
    _ = @import("apprt/ipc/state.zig");
    _ = @import("apprt/ipc/events.zig");
    _ = @import("apprt/ipc/pane.zig");
    _ = @import("apprt/ipc/handler.zig");
    _ = @import("apprt/ipc/server.zig");

    // Compile-time reach of the real-runtime bridge: the reason this root
    // exists. `app_host.zig` has no tests of its own, so this line is what
    // puts it in the build graph.
    _ = app_host;
}

test "app_host: availability contract matches the built artifact" {
    // This documents the shallow-compile caveat in the header. If someone
    // builds the windowed runtimes this branch stops firing, which is the
    // signal that the vtable bodies are now genuinely being analyzed.
    if (windowed) {
        try std.testing.expectEqualStrings("", app_host.unavailableReason());
    } else {
        const reason = app_host.unavailableReason();
        try std.testing.expect(reason.len > 0);
        std.debug.print(
            "app_host is compiled but NOT windowed (artifact={s}): {s}\n",
            .{ @tagName(build_config.artifact), reason },
        );
    }
}
