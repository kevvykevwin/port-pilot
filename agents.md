# Port Pilot

Native macOS menu bar app for managing local dev ports. Swift 6, SwiftUI, SPM.

## Build & Test

```bash
swift build              # debug build
swift build -c release   # release build
swift test               # 15 XCTest tests
swift run PortPilot      # launch menu bar app (GUI)
./scripts/build-app.sh   # build .app bundle with ad-hoc signing
```

## Project Structure

```
Sources/
├── PortPilotCore/       # library target (models, services, view models)
│   ├── Models/          # PortEntry, PortSnapshot
│   ├── Services/        # LibProc, LsofScanner, PortScanner, ProjectResolver, ProcessKiller
│   └── ViewModels/      # PortStore (+ GroupMode, PortGroup, PortCategory)
└── PortPilot/           # executable target (SwiftUI app)
    ├── PortPilotApp.swift  # @main, MenuBarExtra, LighthouseIcon
    └── Views/              # MenuBarView, PortListView, PortRowView, EmptyStateView
Tests/
└── PortPilotTests/      # XCTest suite
```

## Key Patterns

- **Two targets**: `PortPilotCore` (library, all logic) + `PortPilot` (app, SwiftUI views). All core types are `public`.
- **Scanner protocol**: `PortScanning` — `LsofScanner` is primary (setuid root visibility), `PortScanner` (libproc) is fast fallback. Mock via protocol for tests.
- **Unsafe code isolation**: All `proc_*` C interop lives in `LibProc.swift`. Uses Array buffers, not manual allocate/deallocate.
- **Concurrency**: `LsofScanner` uses `withCheckedThrowingContinuation` (not blocking `waitUntilExit`). `PortStore` polling uses `[weak self]` inside loop body with cancellation break.
- **Thread safety**: `ProjectResolver` cache uses `NSLock` + `withLock` helper (defer-scoped). Cache keyed on `(PID, processStartTime)` to handle PID reuse.
- **macOS app detection**: `PortCategory.isMacApp()` — single source of truth. Checks executable path (`/Applications/`, `.app/`, `/System/`) and known process names.
- **Menu bar icon**: `NSImage` drawn via `NSBezierPath` (not Canvas/SF Symbol — those don't render in `MenuBarExtra` labels). `isTemplate=true` for light/dark auto-tinting, `isTemplate=false` for amber beacon.

## Testing

- Tests use XCTest (requires Xcode or Xcode Command Line Tools with full Xcode installed)
- Scanner tests spawn real TCP listeners and processes — they test against the live system
- PortStore tests use `MockScanner` for deterministic results
- `@MainActor` tests for PortStore (it's `@Observable @MainActor`)

## Conventions

- Swift 6 strict concurrency
- `Sendable` on all models and services
- No external dependencies (zero SPM packages)
- Non-sandboxed (required for `proc_*` and `lsof` access)
- `LSUIElement=true` in Info.plist (no Dock icon)

## Compound Learnings

### 2026-06-14
- **VSCode false positive handling**: Developer encounters VSCode-related warnings/errors that appear to be false positives and seeks to distinguish between actual issues vs. tool artifacts that can be safely resolved or ignored
- **Streamlined deployment workflow**: Developer uses a compact command sequence pattern: "commit these, /deploy and open a PR" suggesting a preference for batched operations rather than individual git/deployment steps
- **Post-merge cleanup with numbered steps**: Developer has a systematic `/post-merge-cleanup` command with numbered parameters (6) indicating a structured checklist approach for handling specific cleanup tasks after merges
- **Local app refresh workflow**: Developer expects to update/restart the locally running PortPilot app after changes, suggesting the development cycle includes live testing of the menu bar app during iteration

### 2026-05-18
- **Post-merge cleanup workflow**: Developer has a systematic `/post-merge-cleanup` command pattern with numbered steps (4, 5) suggesting a structured checklist approach for handling merge aftermath tasks
- **Version bump oversight**: Developer acknowledges missing version bumps during deployment but chooses to defer to next PR rather than interrupt current workflow, indicating preference for forward momentum over immediate corrections
- **Worktree deployment pattern**: Uses git worktrees for commit/deploy/PR workflow, suggesting a branching strategy that isolates deployment preparation from main development work

### 2026-04-10
- **Proactive port management**: Developer is exploring auto-rerouting and conflict detection for dev servers, suggesting the project is evolving from passive monitoring to active port management with automatic conflict resolution
- **Uncertainty with testing**: Developer questions if tests "were tested properly" when reviewing implementation, indicating a pattern of double-checking test coverage and validity after feature implementation
- **Git hook project isolation**: Developer specifically asks about making post-merge hooks project-specific rather than global, showing preference for contained automation that doesn't affect other repositories
- **Release automation workflow**: Developer follows a consistent pattern of integrating tests → opening PR → updating local version → bumping release numbers as a single workflow step
