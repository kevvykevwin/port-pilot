# Port Pilot — Progress

## Current State

**Version**: v0.1.0 (released)
**Branch**: `feat/always-poll` (PR #1 open → main)
**Tests**: 15/15 passing (`swift test`)
**Build**: clean (release)
**Repo**: https://github.com/kevvykevwin/port-pilot

## What Works

- [x] Port scanning via `lsof` (setuid root, full visibility)
- [x] `libproc` fast scanner (fallback, limited visibility)
- [x] Project detection — resolves process cwd → `.git`/`package.json`/`pyproject.toml` roots
- [x] Smart categorization — dev servers vs macOS apps by process identity (not just port range)
- [x] SwiftUI menu bar app via `MenuBarExtra(.window)`
- [x] Lighthouse icon (NSImage template, auto light/dark tinting)
- [x] Amber beacon glow when multi-port projects detected
- [x] Two-click kill with SIGTERM → SIGKILL grace flow
- [x] Grouped views: Project | Type
- [x] Collapsible sections (macOS Apps + High Ports collapsed by default)
- [x] Search/filter by port, process name, project
- [x] IPv6 dedup
- [x] Infrastructure port warnings (Portless, Docker)
- [x] Copy to clipboard (port, PID, kill command)
- [x] Background polling on app launch (beacon reflects state without opening popover)
- [x] Low power mode detection (2s → 5s polling)
- [x] Ad-hoc code signing + .app bundle packaging

## Architecture

```
PortPilotCore (library)
├── LsofScanner        — primary scanner (lsof -F pcn, async continuation)
├── PortScanner        — libproc-based fast scanner
├── ProjectResolver    — PID → cwd → project root (LRU cache, NSLock + withLock)
├── PortStore          — @Observable, search, grouping, polling, IPv6 dedup
├── ProcessKiller      — KillResult enum, graceful termination
├── PortEntry          — composite ID, Sendable
└── PortSnapshot       — diff logic

PortPilot (app)
├── PortPilotApp       — MenuBarExtra + lighthouse NSImage icon
├── MenuBarView        — search + group toggle + status bar
├── PortListView       — collapsible sections
├── PortRowView        — port info + kill + context menu
└── EmptyStateView     — helpful empty state
```

## Key Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Scanner | `lsof` primary, `libproc` fallback | `proc_pidinfo` has visibility limits even for user-owned processes |
| UI framework | SwiftUI `MenuBarExtra(.window)` | Modern API, no NSStatusItem/NSPopover bridging needed |
| Icon | NSImage with `isTemplate=true` | Canvas/SF Symbols don't render in MenuBarExtra labels |
| Cache key | `(PID, processStartTime)` | Prevents PID reuse returning stale project |
| Concurrency | `withCheckedThrowingContinuation` for lsof | Avoids blocking cooperative thread pool |
| Polling | App.init() not MenuBarView.onAppear | Beacon reflects state without opening popover |

## Test Coverage

| Component | Tests | Type |
|-----------|-------|------|
| LsofScanner | 1 | Integration (live system) |
| PortScanner | 2 | Integration (spawn listener + self-test) |
| PortSnapshot | 2 | Unit (canned diff data) |
| ProjectResolver | 3 | Unit (cache, markers, setup) |
| PortStore | 6 | Unit (search, grouping, dedup) |
| ProcessKiller | 1 | Integration (spawn + kill process) |

## v0.2 Roadmap

- [ ] Global hotkey (Cmd+Shift+P) — deferred to avoid Accessibility permission
- [ ] Docker container awareness
- [ ] Favorites/bookmarks, port labels
- [ ] Notifications/guard mode
- [ ] Privileged helper for root process kills
- [ ] Homebrew cask distribution
- [ ] Port history
- [ ] Kill result feedback in UI (currently discarded)
- [ ] LsofScanner error logging (currently silent)
- [ ] Edge case tests for lsof parsing (malformed input)

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
