# Port Pilot — Progress

## Current State

**Version**: v0.4.0 (build 3, release prepared)
**Tests**: `swift test`
**Build**: clean (release)
**Repo**: https://github.com/kevvykevwin/port-pilot

## What Works

- [x] Resilient port scanning — `lsof` primary, `libproc` fallback, explicit failure state
- [x] Healthy results retained when every scanner is unavailable
- [x] Project detection — resolves process cwd → full `.git`/`package.json`/`pyproject.toml` root identity
- [x] Equal project basenames remain separate and receive minimally disambiguated labels
- [x] Smart categorization — dev servers vs macOS apps by process identity (not just port range)
- [x] SwiftUI menu bar app via `MenuBarExtra(.window)`
- [x] Lighthouse icon (NSImage template, auto light/dark tinting)
- [x] Amber beacon glow when multi-port projects detected
- [x] Identity-safe two-click kill with SIGTERM grace period and separately confirmed SIGKILL
- [x] Address-aware TCP listener conflict detection + debounced notifications
- [x] Grouped views: Project | Type
- [x] Collapsible sections (macOS Apps + High Ports collapsed by default)
- [x] Search/filter by port, process name, project
- [x] IPv6 dedup
- [x] Infrastructure port warnings for known local development services
- [x] Copy to clipboard (port, PID, kill command)
- [x] Adaptive polling: 2s active, 30s background, 60s background Low Power Mode
- [x] Generation-guarded refresh publication for overlapping scans
- [x] Ad-hoc code signing + .app bundle packaging

## Architecture

```
PortPilotCore (library)
├── ResilientPortScanner — lsof primary + libproc fallback
├── ProjectResolver      — PID → cwd → full project root (LRU cache, NSLock)
├── ConflictDetector     — address-aware TCP listener overlap
├── PortStore            — serialized publication, search, grouping, adaptive polling
├── ProcessKiller        — PID-identity-safe graceful/forced termination
├── PortEntry            — listener data + full project-root identity
└── PortSnapshot       — diff logic

PortPilot (app)
├── PortPilotApp       — MenuBarExtra + lighthouse NSImage icon
├── ConflictNotifier   — debounced macOS conflict notifications
├── MenuBarView        — search + group toggle + status bar
├── PortListView       — collapsible sections
├── PortRowView        — port info + kill + context menu
└── EmptyStateView     — helpful empty state
```

## Key Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Scanner | `lsof` primary, `libproc` fallback | `proc_pidinfo` has visibility limits even for user-owned processes |
| Scan failure | Keep last healthy result | An unavailable scanner must not look like every process stopped |
| UI framework | SwiftUI `MenuBarExtra(.window)` | Modern API, no NSStatusItem/NSPopover bridging needed |
| Icon | NSImage with `isTemplate=true` | Canvas/SF Symbols don't render in MenuBarExtra labels |
| Cache key | `(PID, processStartTime)` | Prevents PID reuse returning stale project |
| Project identity | Full standardized root path | Equal basenames must not merge or create false multi-port warnings |
| Concurrency | `withCheckedThrowingContinuation` for lsof | Avoids blocking cooperative thread pool |
| Refresh state | Newest generation publishes | Manual and polling scans may overlap |
| Polling | 2s active / 30s background / 60s low power | Keep visible data fresh without continuous background energy use |
| Termination | Verify PID start time before each signal | Prevent signaling a reused PID |

## Test Coverage

Run the complete XCTest suite with `swift test`. It covers scanner parsing and
fallback behavior, live listener discovery, project-root resolution and basename
collisions, refresh ordering, conflict detection/notification filtering, snapshot
diffs, and process termination identity checks.

## Future Ideas (not shipped)

- [ ] Global hotkey (Cmd+Shift+P) — deferred to avoid Accessibility permission
- [ ] Docker container awareness
- [ ] Favorites/bookmarks, port labels
- [ ] Notifications/guard mode
- [ ] Privileged helper for root process kills
- [ ] Homebrew cask distribution
- [ ] Port history

## Session Log

| Date | Action | Outcome |
|------|--------|---------|
| 2026-03-22 | Initial build (v0.1) | 18 files, 1728 lines, 14 tests |
| 2026-03-22 | XCTest migration | Converted from custom runner, 15/15 passing |
| 2026-03-22 | .app bundle + build script | 596KB binary, ad-hoc signed, LSUIElement |
| 2026-03-22 | Lighthouse icon | NSImage template, amber beacon for multi-port |
| 2026-03-22 | Smart categorization | Dev servers vs macOS apps by process identity |
| 2026-03-22 | Code review + simplifier | Fixed concurrency, ARC, lock safety, DRY |
| 2026-03-22 | Deployed to GitHub | v0.1.0 release, MIT license |
| 2026-03-23 | Always-poll PR #1 | Beacon reflects state on launch |
| 2026-06-13 | VS Code extension false-positive fix | Pylance/Code Helper helpers no longer surface as phantom projects; group under macOS Apps |
| 2026-07-29 | v0.4.0 reliability release prepared | Worktree roots, PID-safe kill flow, serialized refreshes, scanner fallback, address-aware conflicts, and full-root project identity |
