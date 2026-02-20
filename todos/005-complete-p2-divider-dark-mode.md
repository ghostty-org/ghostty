---
status: complete
priority: p2
issue_id: "005"
tags: [code-review, visual, dark-mode]
dependencies: []
---

# Sidebar Divider Color Does Not Update on Dark/Light Mode Switch

## Problem Statement

`NSColor.separatorColor.cgColor` captures a static CGColor at construction time. When the user switches between light and dark mode, the divider remains the original color.

## Findings

- **Architecture Strategist**: Risk 6 — "divider color does not respond to appearance changes"
- **Performance Oracle**: Finding 3.4 — "not dynamic-color aware"

## Proposed Solutions

### Option A: Override viewDidChangeEffectiveAppearance (Small effort)
```swift
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    dividerView.layer?.backgroundColor = NSColor.separatorColor.cgColor
}
```

### Option B: Use NSBox as separator (Small effort)
Replace the raw NSView with `NSBox(frame:)` styled as `.separator`. NSBox handles appearance changes automatically.

## Recommended Action

Option A — one method override, 3 lines.

## Acceptance Criteria

- [ ] Switch system appearance from light to dark → divider updates
- [ ] Switch from dark to light → divider updates

## Work Log

| Date | Action | Result |
|------|--------|--------|
| 2026-02-20 | Identified by Architecture Strategist + Performance Oracle | P2 finding |
