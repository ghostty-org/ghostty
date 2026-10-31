# Test the automatic deployment path

Use an isolated development build, not release OMG. Open Settings → Shell & Sessions → Session Runtime.
Enter an SSH alias or `user@host` and Connect. The app deploys matching bundled
runtime artifacts; no local checkout, test-vps-jump script or remote compiler is
required on this path. SSH config carries ports/jump hosts/keys. Password and host
key prompts use SSH askpass. Unsupported platforms or setup errors are visible.

Lifecycle settings apply to newly created Sessions. Default detached lifetime is
72 hours (3 days); 0 disables only that time limit. An optional ISO-8601 cutoff applies
only while detached. Completion cleanup is an opt-in Beta feature, off by default, with a 60-second grace
period and validated Agent hooks/conversation stores. It is independent of the TTL:
completion can retire a session early, while an unfinished session still expires
at the maximum detached lifetime. Grace begins when both detach and completion
have occurred; new work or reattach cancels that completion cleanup. Connections install the current
OMG Codex/Claude/Pi hooks when remote Python 3 is available. No Python means terminal
persistence still works, but completion cleanup/recovery cannot be assumed.

Checks:

1. Connect, inspect remote hostname/PID, split and create tabs. Splits inherit the
   host with a distinct PID. New tabs start locally in the pre-SSH directory, as
   do new local windows. Two configured hosts must not share sessions.
2. Cmd-Q and reopen the same development build normally. No test launcher is needed for descriptor
   panes. Layout, IDs and still-live remote PIDs must match. Warm restoration uses
   a single SSH connection to the pinned runtime; it must not repeat deployment
   probes or hook installation. Only an explicit missing-runtime response falls
   back to deployment.
3. Set a short detached TTL for a new session, disconnect and wait. Its process
   should terminate; reopen displays an ended-session error for ordinary shells.
   Output alone must not prevent expiry. Check the record's reason remotely.
4. With a supported real Agent, record its conversation ID, let its task complete
   while detached, and wait through the grace period. Ordinary reconnect must
   report the retired session. Explicit eligible-generation resume may start a
   new PID with the original conversation; missing conversation metadata/file
   must fail visibly, never silently start a fresh conversation.
5. Existing live sessions keep their policy and runtime revision. App updates may
   reuse a cached runtime only if the snapshot compatibility hash matches and the
   host advertises `strict-open/1`. Incompatible hosts/cores preserve the remote
   process and report the mismatch; the matching earlier app can still access it.
6. Start from a local terminal with visible history, then enter an interactive
   `ssh host`. SSH opens as a sibling native tab; the local tab and original
   shell remain accessible. Closing or exiting SSH must not replace that local
   Surface. The settings entry must use the current workspace's tab group too.
7. With two runtime panes on one connection, interrupt only their SSH transport.
   Both retain their current display and report reconnection. Restore the network:
   both reattach without user intervention and retain UUID/PID. Input during the
   gap must not execute later. Retry Now on one failed stream must not disconnect
   a healthy sibling. Bad authentication must stop at attention without an
   askpass loop.
8. Create a local background session, record its PID, split, then quit/reopen.
   The same daemon/protocol must retain those PIDs. Git/files/history context
   remains local. Existing ordinary local sessions must not be migrated.

Ordinary interactive `ssh host` in an integrated local shell now uses this native
path. Remote commands and tunnels retain system SSH semantics. Current release
gates remain in RELEASE_PROGRESS.md: real sleep/wake/network/authentication
acceptance, a full management UI, and real vendor Agent/cross-platform execution
acceptance are required before public release.
