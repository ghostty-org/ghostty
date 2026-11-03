# Quit retention preferences and native tab icon sizing

## Behavior

Shell & Sessions settings now expose independent local and managed SSH quit
preferences. `sessions.keepLocalOnQuit` and `sessions.keepSSHOnQuit` both default
to true, preserving the existing background runtime behavior. Ordinary PTYs
still end with the application. The preferences apply to the app's open and
checkpointed sessions, including parked workspaces, without changing individual
pane/window Close semantics or unrelated sessions on a shared host.

| Keep local | Keep SSH | Accepted app quit |
| --- | --- | --- |
| On | On | Keep both runtime categories running. |
| Off | On | End local carriers; retain the original remote session UUID. |
| On | Off | Retain local shells; request Close for owned remote sessions. |
| Off | Off | Request Close for both categories. |

The quit adapter covers immediate termination and accepted asynchronous
confirmation/review. It persists the final checkpoint and Close intents before
committing native termination presentation and starting cleanup. Cancellation
before acceptance sends no new Close requests; checkpoint cancellation restores
the live pane identities if preparation fails.

SSH cleanup runs before local carrier cleanup. Existing authenticated inline
relay sockets are preferred, including password-authenticated sessions. Each
category has a two-second wait budget, at most 16 concurrent control helpers,
and bounded retries. Unconfirmed closes stay durable for a later connection.
The existing relay/control-master shutdown then runs normally. No daemon or
recorded remote PID is killed to implement this preference.

Sessions ended at quit receive new checkpoint pane IDs and a one-shot
`runtimeCreateOnRestore` flag, so Restore Sessions creates a fresh process rather
than attaching an explicitly closed UUID. Retained inline SSH sessions keep the
original remote UUID when their local carrier ends. The tab/split layout and
focused-pane mapping are preserved. Disabling automatic local runtime still
allows fresh ordinary local PTYs on restoration.

Native single-pane logos now occupy 22-24 points inside the existing 26-point
footprint (24 points at the default setting), instead of the previous 17-18.
The multi-pane layout and shared source images are unchanged. A native AppKit
preview verifies terminal/cloud singles and two-, three-, and four-pane layouts.

## Validation

Final source validation on 2026-11-03:

- All 1,394 routine Swift tests in 174 suites passed in one host in 304.547
  seconds. The preceding broad run also passed before the final native
  termination freeze was added.
- The real 60-tab native fullscreen termination regression passed in 12.747
  seconds, after verifying and activating the checkout's running test host.
- Nine new quit-policy tests cover independent preference persistence, all four
  policy combinations, inline carrier independence, fresh checkpoint IDs and
  focus, cancellation recovery, acknowledged versus pending Close, timeout
  helper cleanup, localized confirmation copy, and 40-request concurrency.
- Four existing real-PTY relay/durable-Close Python tests passed using isolated
  fixtures and a fake SSH transport.
- All 42 selector contracts passed. Strict Swift lint reported zero violations
  across 575 files. Documentation, schema, plist, and whitespace checks passed.
- Native preview outputs: `/tmp/omg-native-tab-icon-sizes.png` and
  `/tmp/omg-quit-policy-settings.png`. Full local evidence is under
  `/tmp/omg-quit-policy-20261103/`.

No actual user SSH host was terminated or restarted for this validation. Real
remote authentication and process retention across an installed-app quit/reopen
remain separate acceptance checks. Other optional desktop suites and XCUITest
were not run. This source change does not replace the published 0.19.0 artifacts.
