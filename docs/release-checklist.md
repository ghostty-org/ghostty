# Ghostties Release Checklist

Follow these steps before tagging any release. The tag triggers CI — everything before the tag is manual.

## Before tagging

- [ ] All PRs for this release merged to `main`
- [ ] Full test suite green (`Cmd+U` in Xcode)
- [ ] **Update `CHANGELOG.md`** — add a new section at the top for the new version with plain-language notes (no PR numbers, no hashes). This is the source of truth for all release copy.
- [ ] **Update `web/appcast-beta.xml` description** — copy the changelog section into the `<description><![CDATA[...]]></description>` block for the new item. This is what users see in the Sparkle update dialog.
- [ ] Smoke test the key fixes on a local build

## Tagging

```bash
git tag v0.1.0-beta.XX && git push origin v0.1.0-beta.XX
```

CI will: build + notarize the DMG → publish GitHub release → auto-bump appcast XML version/URL/hash.

## After CI completes (~20 min)

- [ ] **Update GitHub release body** — paste the changelog section into the GitHub release notes. CI creates the release but doesn't write the body.
- [ ] Verify `ghostties.org/appcast-beta.xml` is live and shows the new version
- [ ] Smoke test: install DMG, confirm Sparkle finds next update (if applicable)

## Distribution surfaces checklist

| Surface               | Updated by                          | Content                |
| --------------------- | ----------------------------------- | ---------------------- |
| `CHANGELOG.md`        | Manual (before tag)                 | Source of truth        |
| Sparkle dialog        | Manual (before tag, in appcast XML) | From CHANGELOG         |
| GitHub release body   | Manual (after CI)                   | From CHANGELOG         |
| ghostties.org appcast | CI auto-bump                        | Version + DMG URL only |
