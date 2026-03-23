# Brainstorm: Port Pilot Icon Design

Date: 2026-03-22
Status: decided

## Problem
Port Pilot needs a distinctive menu bar icon (22x22pt) that communicates port/network management and is instantly recognizable among other menu bar utilities.

## YAGNI Assessment
Custom icon justified — at 22px in a crowded menu bar with 5+ utilities, a generic SF Symbol (like `network`) is indistinguishable. A distinctive icon makes the menu bar scannable.

## Scope Posture: REDUCTION
Menu bar icon only (22x22pt). No app icon, no animated states in v0.1.

## Context
- Reference app: Ice (jordanbaird/Ice) — clean, minimal menu bar aesthetic
- User runs multiple menu bar utilities daily
- Icon needs to work in both light and dark mode (template rendering)
- Must read clearly at 22px with no antialiasing blur

## Approaches Considered

### A: Ship Wheel / Helm
Summary: Simplified 6-spoke ship's wheel. Classic nautical, spokes suggest connections from hub.
Pros: Iconic, scales well at small size, dual metaphor (steering + connections)
Cons: Could read as "settings gear" at 22px — too similar to System Preferences
Effort: low | Risk: med (gear confusion)

### B: Anchor
Summary: Minimal anchor glyph — universal harbor/port symbol.
Pros: Universal "port" association, clean vertical form, simple geometry
Cons: Could look like a religious icon, generic nautical feel, many apps already use anchors
Effort: low | Risk: low

### C: Compass Rose
Summary: 4-point compass star — navigational instrument. Diamond shape is distinctive.
Pros: Distinctive diamond shape among circles/squares, center dot = your machine
Cons: Might read as "location/GPS" — wrong association for a port manager
Effort: low | Risk: med (GPS confusion)

### D: Lighthouse Beacon
Summary: Minimal lighthouse silhouette with asymmetric light beam shooting right.
Pros: Totally unique in menu bar ecosystem, perfect "guiding ships into port" metaphor, vertical form fits narrow slot, future potential for beacon pulse animation
Cons: Most complex at small size, requires careful simplification
Effort: med | Risk: low

## Decision
**Chose: Approach D — Lighthouse Beacon**
**Because:** Unique iconography (no other menu bar app uses it), perfect metaphor mapping (lighthouse guides ships to port = app guides you to your ports), vertical form factor is ideal for menu bar, asymmetric light beam adds energy and instant recognition.
**Tradeoffs accepted:** Slightly more complex to render clearly at 22px. May need simplified fallback version if detail doesn't read.

## Design Specifications
- 22x22pt, solid black fill with `shape-rendering="crispEdges"`
- Template rendering mode (macOS auto-tints for light/dark)
- Asymmetric light beam shooting right — signature element
- Tapered tower legs for authenticity
- Convert to PDF vector for Xcode Asset Catalog

## Next Steps
- [x] Create SVG at Assets/icon.svg
- [ ] Convert to PDF for Xcode Asset Catalog (during UI phase)
- [ ] Test at 1x and 2x resolution on retina display
