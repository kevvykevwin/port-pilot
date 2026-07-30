# Port Pilot

Native macOS menu bar app for managing local dev ports. Swift 6, SwiftUI, SPM.

## Build & Test

```bash
swift build              # debug build
swift build -c release   # release build
swift test               # run the XCTest suite
swift run PortPilot      # launch menu bar app (GUI)
./scripts/build-app.sh   # build .app bundle with ad-hoc signing

./Tests/shell/test-auto-update.sh   # tests for the unattended installer (sandboxed, no Swift build)
./scripts/auto-update.sh --dry-run  # what the updater would do right now
./scripts/release.sh --dry-run      # validate a release without tagging
```

## Project Structure

```
Sources/
├── PortPilotCore/       # library target (models, services, view models)
│   ├── Models/          # PortEntry, PortConflict, PortSnapshot
│   ├── Services/        # scanners, project/conflict resolution, process termination
│   └── ViewModels/      # PortStore (+ GroupMode, PortGroup, PortCategory)
└── PortPilot/           # executable target (SwiftUI app)
    ├── PortPilotApp.swift  # @main, MenuBarExtra, LighthouseIcon
    ├── Services/           # ConflictNotifier
    └── Views/              # MenuBarView, PortListView, PortRowView, EmptyStateView
Tests/
└── PortPilotTests/      # XCTest suite
```

## Key Patterns

- **Two targets**: `PortPilotCore` (library, all logic) + `PortPilot` (app, SwiftUI views). All core types are `public`.
- **Scanner protocol**: `PortScanning` — `ResilientPortScanner` uses `LsofScanner` as primary and `PortScanner` (libproc) as fallback. Explicit scan failures retain the last healthy UI state. Mock via protocol for tests.
- **Unsafe code isolation**: All `proc_*` C interop lives in `LibProc.swift`. Uses Array buffers, not manual allocate/deallocate.
- **Concurrency**: `LsofScanner` uses `withCheckedThrowingContinuation` (not blocking `waitUntilExit`). `PortStore` polling uses `[weak self]` inside loop body with cancellation break.
- **Refresh publication**: `PortStore` generations ensure only the newest overlapping scan can publish entries, snapshots, errors, and callbacks.
- **Thread safety**: `ProjectResolver` cache uses `NSLock` + `withLock` helper (defer-scoped). Cache keyed on `(PID, processStartTime)` to handle PID reuse.
- **Project identity**: `PortEntry.projectPath` stores the full standardized root path. UI labels use the final component and add minimal parent context when equal basenames are displayed together.
- **Process termination**: Verify `(PID, processStartTime)` before every signal. SIGTERM gets a grace period; SIGKILL requires a separate confirmation and another identity check.
- **Polling cadence**: 2s while the menu is open, 30s in the background, and 60s in background Low Power Mode.
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
- **Version lives only in the `VERSION` file.** `scripts/build-app.sh` parses it to stamp `Info.plist`, `scripts/release.sh` parses it for the `v<version>` tag, and `scripts/auto-update.sh` compares it against the installed bundle. Never hardcode a version anywhere else — it drifted across four places before this was centralised.
- Shell scripts in `scripts/` are covered by `Tests/shell/`, not XCTest. `auto-update.sh` replaces the bundle in `/Applications` unattended, so treat its failure paths as load-bearing: every one must leave a launchable app installed.

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
