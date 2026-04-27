# Principles: Ghostties

## Always

**Front-load setup, then disappear.** The first moments are the highest-leverage surface. Get people to value fast — show them the right thing, get them running — then recede. A sidebar that keeps demanding attention is a failed sidebar.

**Keep the terminal footprint light.** Ghostties lives inside a terminal emulator it doesn't own. Every layer it adds is weight. Prefer thin integrations, minimal state, and surfaces that don't compete with the terminal itself.

**Honor macOS conventions.** When there's a native way — system dark mode, keyboard shortcuts, window behavior — use it. Don't reinvent what the platform already solved.

## Resist (not never, but resist)

**IDE drift.** Every feature that adds file trees, editors, debuggers, or build tooling pulls Ghostties toward an IDE and away from a focused workspace. Some of this may be right eventually. When the impulse surfaces, ask: does this serve the agent runner, or does it serve the app?

## When in doubt

**Simpler.** If two implementations both work, the one with fewer moving parts wins.

**Native over custom.** If macOS already does it, use what macOS already does.

**Does this serve the person running parallel agents?** That's the filter. Features that serve the sidebar as a workspace belong. Features that serve a different use case — even a good one — probably don't belong yet.

## How to apply

Read this at every implementation fork. The question isn't "is this a good feature?" but "is this the right feature for a workspace sidebar on a terminal?" When two valid paths exist, simpler and native win.
