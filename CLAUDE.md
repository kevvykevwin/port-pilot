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
