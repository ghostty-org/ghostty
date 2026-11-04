# Pane presentation and Quick Input regressions

Baseline: `fe9fa07f5`. Priority: preserve the original pane after splitting.

## Surface ownership

The new regression creates two successive native scroll wrappers for one
retained Ghostty Surface. Before the fix, layout of the retired wrapper changes
the remounted Surface to zero or the retired wrapper's size. Both assertions
failed. Only the current document parent may now mutate the Surface's geometry,
scroll position or core resize state. Transient zero viewport proposals retain
the last drawable frame. Repeated splits and composer/queue geometry changes
also exercise the original Surface without replacing its identity.

## Composer presentation

The supplied video shows an old terminal layout during the transition between
105x45 and 105x27. The native dock now assigns its final frames before updating
the hosted leaves. One-shot composer changes no longer masquerade as window
live-resize interactions. Draft import starts from the native editor's ready
callback after layout; hidden, parked and unselected presentations cannot take
focus or start the handshake. The short snapshot remains limited to a real
external-editor request.

These contracts are covered by layout and real-PTY editor tests. Pixel-perfect
foreground animation acceptance still requires a working computer-control
connection; the current native pipe fails to start.

## Managed SSH draft bridge

Managed SSH had bypassed the legacy SSH bootstrap's editor/session registration.
New runtime PTYs now provision the existing Python editor protocol in their
private state directory. The Mac resolves a stable runtime UUID, generation,
live record and TTY instead of requiring a transient legacy connection ID.
Requests reject generation changes; reads preserve the source draft exactly.
Ordinary editing still delegates to the previous editor. If Python is absent,
the runtime preserves the original editor environment.

The bridge's source participates in the artifact revision. Teardown removes
only the matching generation's private draft data. No daemon wire format is
changed. Older pinned daemons and already-running Agent environments remain
intact; enabling this bridge for them requires a new SSH session and Agent
resume at a user-chosen time.

## Status and queued input

Native logos restore blue selection/foreground breathing and purple background
work. Both tab orientations share green completion, orange question/permission
and red failure badges, including the original question bubble and shield.

Completion during draft import previously lost its dispatch opportunity.
Finishing/canceling import now reevaluates done queues; automatic submission
allows the Stop hook to return and then checks the current activity and target.
Local dispatch also verifies foreground Agent identity. Secure Input recovery
reads the committed value rather than its pre-change publication. A real PTY
regression verifies a queued Codex message is sent once after import unblocks.

## Delivery constraint

The running baseline stores unsent Quick Input drafts/queues only in memory.
The user reported unsent queued messages, and computer control is unavailable
to verify that they have been saved. Prepare and validate the new app, but do
not restart the running Dev until those contents are handled. Runtime PTY
retention alone does not preserve this UI-only state.
