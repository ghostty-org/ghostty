# Native SSH runtime release progress

Work in progress, not released. Existing experimental vps-jump host was not
restarted. New deployment tests use content-versioned runtime directories.

Implemented in this change:

- Host-managed per-session policy: detached TTL (72h / 3 days by default), optional UTC deadline,
  opt-in Beta Agent completion grace (disabled by default), bounded termination, idle-host exit, closed record
  retention, active-worker quota release and persistent tombstones.
- Host connection heartbeat (45s lease) detaches abandoned transports. PTY output
  does not extend detached lifetime. Child exit releases the PTY after bounded drain.
- Typed durable Agent recovery records for Codex/Claude/Pi. Hooks report through a
  private token/generation-bound local socket and wait for acknowledgment while the
  reporting process can be validated. Completion cleanup requires a conversation
  file; reattach resumes with a new PID and the same conversation identity.
- Per-pane host/revision/policy descriptors and restoration. Splits inherit the
  host with a new pane UUID; restored panes cannot silently create missing sessions.
  Explicit eligible Agent resume is distinct from automatic reattachment.
- Settings connection entry and policy controls. System SSH uses exact routing,
  keys/config and askpass for interactive authentication. Runtime deployment is
  automatic from bundled artifacts, not from a remote toolchain or arbitrary URL.
- Native macOS arm64/x86_64 and Linux glibc 2.28 x86_64/arm64 build artifacts; universal
  local helper, nested code signing and manifest hash refresh. Versioned app cache
  and remote directories preserve active old runtimes instead of restarting them.

Validation so far:

- Runtime Rust unit/integration tests pass; fixture Agent completion/termination/
  resume test passes; detached output-producing process expires and empty host exits.
- All four artifact architectures build. Linux x86_64 automatic first deployment and
  real SSH create work on vps-jump. A 5s test TTL retired that session and the host
  exited after its idle interval.
- Swift targeted connection/settings/hooks tests: 75 pass; connection/remote-context
  tests: 39 pass. Broad routine run: 1082 tests, one known link-check timing assertion
  failed, isolated retry passed. Signature and 17 signing contracts pass (2 optional
  signing experiments skipped).
- Native App acceptance: a new connection descriptor triggered auto deployment,
  shell input produced the expected marker in the remote VT snapshot, splitting
  created an independent PID, and reopening retained both pane PIDs/generations.
  The prior experimental daemon was not replaced.

Release gaps (do not advertise these as completed):

- Ordinary interactive `ssh host` now hands off through the shell wrapper to the
  native backend. Commands, tunnels, explicit noninteractive/unsupported flags and
  bypassing shell integration retain system SSH semantics. The helper is `omgd`.
  Typed SSH → native surface → GUI quit/reopen preserved PID/generation on vps-jump.
- Real Codex/Claude/Pi task completion and resume acceptance, Linux arm64/macOS remote
  execution and password/host-key UI still need acceptance.
- Runtime revisions are cached independently from the snapshot compatibility hash.
  Cached runtime descriptors require both a matching terminal core hash and the
  host's `strict-open/1` capability. Older hosts and incompatible snapshot cores
  are rejected visibly with their processes retained. A production
  upgrade/migration UI is still needed.
- Explicit pane close sends CLOSE and terminates that session; app quit detaches.
  The 2026-11-01 relay refactor adds automatic transport recovery while preserving
  local sockets and native Surfaces, generation-fenced input, and an attention/
  retry state for authentication and session rejection. Real network sleep/wake
  and password-dialog acceptance are still separate gates.
- Local background sessions share the SSH runtime's descriptor, daemon, snapshot
  and close lifecycle. SSH handoff opens a sibling native tab and releases the
  source local prompt. Ordinary existing local PTYs are not migrated.
- Metadata/status list and explicit restore protocol exist, but full session manager
  UI and local process death reconciliation are still pending.
- Existing terminal side effects and capabilities need parity checks. Arbitrary
  escaped descendants cannot be guaranteed killed without platform containment.
