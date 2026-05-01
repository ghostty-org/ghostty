# Handoff: ghostties.org analytics

Status: not implemented. Decision pending.

## Question

Can we measure download interest on ghostties.org and via GitHub?

## What we already have (free, automatic)

GitHub Releases tracks `Ghostties.dmg` download counts per tag. Pull anytime:

```bash
gh release view v0.1.0-beta.14 --repo SeanSmithDesign/ghostties \
  --json assets --jq '.assets[] | {name, downloads: .download_count}'
```

Snapshot as of 2026-04-30:

| Tag     | DMG downloads    |
| ------- | ---------------- |
| beta.14 | 0 (just shipped) |
| beta.13 | 1 (Sean)         |
| beta.12 | 3                |
| beta.10 | 2                |
| beta.9  | 2                |

About 8 organic downloads since 2026-04-26. No funnel data — only the click-through count.

## What's missing

- Visit count on `/` and `/download` (don't know how many landed but didn't click)
- Referrer / source breakdown
- Geo / device split

## Privacy constraint (read this first)

`web/privacy.html` currently states: **"Nothing. No telemetry, no analytics, no crash reports."** Adding any analytics breaks that promise. Update the page before adding instrumentation, or skip it.

## Recommended option (if proceeding)

**PostHog** — Sean already uses it for Brukas (org `Sean Smith Design`, claude.ai PostHog MCP integration available).

Steps for a follow-up agent:

1. **Create a Ghostties project in PostHog** under the existing org. Get its `api_token` (a `phc_…` key).
   - PostHog API or UI. The MCP tool `mcp__claude_ai_PostHog__switch-project` lists projects; the org currently has `Brukas` (id 400385) and `Default project` (id 270551). Either repurpose Default or create a fresh "Ghostties" project.
2. **Drop the snippet** into `web/index.html` and `web/download.html` (just before `</head>`):
   ```html
   <script>
     !function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){...})}(document,window.posthog||[]);
     posthog.init('phc_YOUR_KEY', { api_host: 'https://us.i.posthog.com', capture_pageview: true });
   </script>
   ```
   (Use the official snippet from the PostHog "Web installation" docs; the above is illustrative.)
3. **Track the download click** in `web/download.html`:
   ```html
   <a
     class="download-btn"
     href="..."
     onclick="posthog.capture('dmg_download_click', {version:'v0.1.0-beta.14'})"
   ></a>
   ```
4. **Update `web/privacy.html`** to honest copy:
   > Anonymous, aggregate page-view counts via PostHog. No cookies, no PII, no IP storage. Used to understand whether Ghostties is finding people.
5. **Validate**: visit ghostties.org in a private window, confirm the event lands in PostHog within ~1 minute.

## Alternative: skip and stay GitHub-only

If "no analytics" is more important than funnel data, do nothing. The GitHub download counts are sufficient signal for a beta.

## Open questions for Sean

- Keep the "no analytics" privacy promise, or update it?
- If proceeding: new PostHog project named "Ghostties", or reuse "Default project"?
- Do we want the same instrumentation on the Ghostties macOS app itself (in-app telemetry) or only on the marketing site?

---

**Author**: orchestrator session 2026-04-30, after the beta.13/beta.14 release flow.
**Linked**: SEA-241 ("Sparkle: surface check-for-update progress + result feedback") — separate issue but same theme: we're flying blind on update success rate.
