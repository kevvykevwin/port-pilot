# Port Pilot — Progress

## Current State

**Version**: v0.4.0 (build 3), unchanged in `VERSION`; no release or install performed.
**Tests**: `swift test` — 118 tests, 0 failures (0.789 s), verified on 2026-10-18. Log: `/tmp/portpilot-tests-final.log`.
**Build**: debug and release builds succeeded. Release log: `/tmp/portpilot-release-build.log` (23.30 s).
**GUI verification**: PARTIAL. SwiftUI seed-window screenshots were inspected (`/tmp/portpilot-project-window.png`, `/tmp/portpilot-type-window.png`) for layout, category labels, the expected-services checkmark, and the fallback freshness footer. Not verified: the installed menu bar app's interactions and kill flows (Sent vs Stopped). Do not treat the reliability work as verified in the running app.
**Working tree**: implementation, tests, README, and this progress log are uncommitted on `main`. The pre-existing `CLAUDE.md` change and untracked `plans/` were preserved. Nothing was committed, installed, released, or pushed.
**Repo**: https://github.com/kevvykevwin/port-pilot

## Last Action

Implemented the six reliability and classification improvements, ran the full XCTest suite and release build, and inspected Project/Type views with seed data. Categorization is deterministic and local; no model integration was added.

## Next Steps

1. Verify installed-app menu interactions and termination feedback before release. Seed-window layout and core behavior are already checked.
2. Review and commit the local changes when requested; installation and release are separate steps.

## What Works

- [x] Resilient port scanning — `lsof` primary (owned child, 5s timeout, 4 MiB output cap), `libproc` fallback, explicit failure state
- [x] Partial or failed `lsof` output triggers fallback; a legitimately empty result (exit 1, no output) is healthy-empty
- [x] Healthy results retained when every scanner is unavailable; footer shows last success age
- [x] Freshness visibility — footer reads "Updated" or "Last success" with a relative age, and "Fallback scan · accessible processes only" when `libproc` was used
- [x] Project detection — resolves process cwd → full `.git`/`package.json`/`pyproject.toml` root identity (500-entry cache keyed by PID + start time)
- [x] Equal project basenames remain separate and receive minimally disambiguated labels
- [x] Deterministic process classification — versioned static catalog (`catalogVersion = 1`), no model or network; unrecognized processes stay Unknown and the port number is only a hint
- [x] Local category overrides — "Category for This Process" / "Use Automatic Category" in the row context menu; keyed by executable plus script or project context, so one Node service cannot relabel every Node process
- [x] Generic runtimes without script or project context cannot receive an override
- [x] Expected services per project — right-click a project heading to remember its current services; the amber review flag is suppressed for that baseline, including restarts; new executables/scripts/ports and duplicate instances still flag
- [x] Socket bindings preserved — `PortStore.entries` keeps every IPv4/IPv6 and wildcard binding; the list shows one row per process incarnation + port + protocol, and the context menu lists all bindings
- [x] Process incarnation identity — row IDs and snapshot diffs use `(pid, process start time)`; a reused PID produces a new row and a new snapshot identity
- [x] Address-aware TCP listener conflict detection; IPv4 and IPv6 are treated as disjoint, wildcards overlap within a family
- [x] Coalesced refreshes — concurrent callers share one scan, one enrichment pass, and one publication; cancelling a waiter does not cancel another caller's refresh
- [x] Generation-guarded publication — only the newest generation publishes; `cancelRefresh()` advances the generation
- [x] Off-main enrichment — scanning and project resolution run in a detached `.utility` task; `lsof` pipes are drained without blocking, and timeout or cancellation signals only the owned child
- [x] Identity-based infrastructure and system-service warnings
- [x] Grouped views: Project | Type; collapsed by default — macOS Apps (Project view); Apps, Editor Services, System (Type view)
- [x] Search/filter by port, process name, project
- [x] Copy to clipboard (port, PID, kill command)
- [x] Identity-safe two-click kill — start time is verified before every signal; SIGTERM grace period; SIGKILL requires separate confirmation and another identity check
- [x] Kill status honesty — row says **Sent** after a signal; only a verified graceful exit shows **Stopped**; the next scan removes exited processes
- [x] Adaptive polling: 2s active, 30s background, 60s background Low Power Mode
- [x] Ad-hoc code signing + .app bundle packaging

## Architecture

```
PortPilotCore (library)
├── ResilientPortScanner — lsof primary (owned child, 5s timeout, 4 MiB cap) + libproc fallback
├── ListenerProcess      — one lsof child; nonblocking pipe drain on a serial queue; SIGKILL on finish/cancel
├── ProcessClassifier    — deterministic, versioned catalog; port numbers are hints only
├── ProcessPreferences   — versioned local overrides (categories, expected services) in UserDefaults
├── ProjectResolver      — PID → cwd → full project root (bounded 500-entry cache)
├── ConflictDetector     — address-aware TCP listener overlap
├── PortStore            — coalesced refresh, off-main enrichment, display-only row aggregation, grouping
├── ProcessKiller        — PID-identity-safe graceful/forced termination
├── PortEntry            — one socket binding; row identity = (pid, start time, port, protocol)
└── PortSnapshot         — diff over binding identity

PortPilot (app)
├── PortPilotApp       — MenuBarExtra + lighthouse NSImage icon
├── ConflictNotifier   — debounced macOS conflict notifications
├── MenuBarView        — search + group toggle + freshness/fallback footer
├── PortListView       — collapsible sections + project review flag + expected services
├── PortRowView        — port info + Sent/Stopped kill states + context menu (category, bindings)
└── EmptyStateView     — helpful empty state
```

## Key Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Scanner | `lsof` primary, `libproc` fallback | `proc_pidinfo` has visibility limits even for user-owned processes |
| Scan failure | Keep last healthy result and its timestamp | An unavailable scanner must not look like every process stopped |
| Display rows | Aggregate for display only; `entries` keeps every socket binding | Collapsing bindings hid IPv4/IPv6 overlap evidence; the aggregation must never be destructive |
| Row / snapshot identity | `(pid, process start time)` plus port and protocol | PID reuse must not carry project, kill, or diff state into a different process |
| Classification | Versioned static catalog; no model or network; unknown stays Unknown | Deterministic and explainable; executable names are descriptive evidence, not verified signatures |
| Category overrides | Keyed by executable plus script or project context | Labeling one runtime service must not relabel every process with the same runtime |
| Expected services | Per project root; key = executable, script, port, protocol | Tolerates normal restarts while still flagging new endpoints and concurrent duplicates |
| UI framework | SwiftUI `MenuBarExtra(.window)` | Modern API, no NSStatusItem/NSPopover bridging needed |
| Icon | NSImage with `isTemplate=true` | Canvas/SF Symbols don't render in MenuBarExtra labels |
| Cache key | `(PID, processStartTime)`, bounded at 500 entries | Prevents PID reuse returning a stale project; bounds memory |
| Project identity | Full standardized root path | Equal basenames must not merge or create false multi-port warnings |
| Concurrency | Owned `lsof` child, nonblocking pipe drain on a serial queue | Avoids blocking the cooperative pool; timeout and cancellation touch only the child we started |
| Refresh state | Concurrent callers share one scan; newest generation publishes | Manual and polling refreshes may overlap |
| Polling | 2s active / 30s background / 60s low power | Keep visible data fresh without continuous background energy use |
| Termination | Verify PID start time before each signal; "Sent" until a verified exit | Prevent signaling a reused PID; never claim a stop that was not observed |

## Test Coverage

Run the complete XCTest suite with `swift test`. Coverage includes:

- Scanner parsing, fallback behavior, and live listener discovery (`PortScannerTests`)
- Bounded `lsof` runs (`BoundedScannerTests`): explicit IPv6 wildcard family, healthy-empty output, large output drained before exit, output cap and timeout terminating only the owned child, cancellation not waiting for the timeout, pre-cancelled scans not launching
- Binding identity (`BindingIdentityTests`): display aggregation cannot hide an IPv6 overlap, same-family distinct addresses preserved, PID reuse changes row and snapshot identity, freshness and source survive a failed scan
- Process classification (`ProcessClassificationTests`) and category overrides
- Project-root resolution and basename collisions (`ProjectResolverTests`)
- Refresh ordering, conflict detection and notification filtering, snapshot diffs
- Process termination identity checks (`ProcessKillerTests`)

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
| 2026-10-18 | Reliability-review recommendations (uncommitted) | Socket bindings preserved with display-only aggregation; process incarnation identity; deterministic classifier catalog with local overrides; coalesced refresh with bounded `lsof` pipe drain, timeout, and cancellation; expected services per project; freshness/fallback footer; Sent vs Stopped kill states. `swift test`: 118 tests, 0 failures (`/tmp/portpilot-tests-final.log`); `swift build -c release` succeeded. Seed-window screenshots inspected; installed-app interactions not UI-tested. No commit, install, or release. |

## Deploy Log

### 2026-10-18 12:01 — feat/process-classification (full)
<!-- deploy:72f6dfd-1792292445-azZfiu -->
- Files: 27 changed (`Sources/ (17), Tests/ (8), (root) (2)`)
  - `Makefile`
  - `README.md`
  - `Sources/PortPilot/PortPilotApp.swift`
  - `Sources/PortPilot/Services/ConflictNotifier.swift`
  - `Sources/PortPilot/Views/MenuBarView.swift`
  - `Sources/PortPilot/Views/PortListView.swift`
  - `Sources/PortPilot/Views/PortRowView.swift`
  - `Sources/PortPilotCore/Models/PortConflict.swift`
  - `Sources/PortPilotCore/Models/PortEntry.swift`
  - `Sources/PortPilotCore/Models/ProcessPreferences.swift`
  - `Sources/PortPilotCore/Services/LibProc.swift`
  - `Sources/PortPilotCore/Services/ListenerProcess.swift`
  - `Sources/PortPilotCore/Services/LsofScanner.swift`
  - `Sources/PortPilotCore/Services/PortScanner.swift`
  - `Sources/PortPilotCore/Services/ProcessClassifier.swift`
  - +12 more
- Commits ahead of origin/main (1):
  - feat: improve listener identity and process classification

### 2026-10-18 11:49 — main (main-commit)
<!-- deploy:29e8e4b-1792291728-b2BxVF -->
- Files: 25 changed (`Sources/ (16), Tests/ (8), (root) (1)`)
  - `README.md`
  - `Sources/PortPilot/PortPilotApp.swift`
  - `Sources/PortPilot/Services/ConflictNotifier.swift`
  - `Sources/PortPilot/Views/MenuBarView.swift`
  - `Sources/PortPilot/Views/PortListView.swift`
  - `Sources/PortPilot/Views/PortRowView.swift`
  - `Sources/PortPilotCore/Models/PortEntry.swift`
  - `Sources/PortPilotCore/Models/ProcessPreferences.swift`
  - `Sources/PortPilotCore/Services/LibProc.swift`
  - `Sources/PortPilotCore/Services/ListenerProcess.swift`
  - `Sources/PortPilotCore/Services/LsofScanner.swift`
  - `Sources/PortPilotCore/Services/PortScanner.swift`
  - `Sources/PortPilotCore/Services/ProcessClassifier.swift`
  - `Sources/PortPilotCore/Services/ProcessKiller.swift`
  - `Sources/PortPilotCore/Services/ProjectResolver.swift`
  - +10 more
- Commits ahead of origin/main (1):
  - Improve listener identity, process categories, and scan reliability
