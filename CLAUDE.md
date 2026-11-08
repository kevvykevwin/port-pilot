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
./Tests/shell/test-cli-arguments.sh  # CLI argument edge cases (needs `swift build` first; runs .build/debug/PortPilotCLI)
sh Tests/shell/test-publication-audit.sh  # publication audit (zip walker, secrets, receipts)
sh Tests/shell/test-publication-final-candidate.sh  # final-candidate publication gate
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
- **Serve route findings**: `PortStore` reads `tailscale serve status --json` (≤1/30 s, only when a `serveReader` is injected — the app passes `TailscaleServeReader`, tests don't), matches loopback targets against the scan, connect-probes only unmatched ones (127.0.0.1/::1 only), and confirms a dead backend after ≥2 dead evaluations spanning ≥60 s. Port Pilot suggests the `serve … off` command; it never changes Tailscale config.
- **No kill for relaunched processes**: `ProcessClassifier.terminationBlockReason` returns why a row offers no kill (Tailscale IPNExtension, macOS ControlCenter); matched by full executable path, never by name.
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

## Learnings log (not loaded)

The nightly dev-journal review used to append dated learnings here. They now live only in the central log, `~/Projects/dev-journal/compound-learnings.md`, under `## <date> <time> — portpilot` headings.

```
grep -A12 -- "— portpilot$" ~/Projects/dev-journal/compound-learnings.md | tail -90
```
