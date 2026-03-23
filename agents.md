# Port Pilot — Agent Guide

Reference for AI agents working on this codebase.

## Quick Context

Port Pilot is a macOS menu bar utility (~600KB) that shows which local ports are in use, which project owns them, and lets you kill processes. Built with Swift 6, SwiftUI, no external dependencies.

## Agent Routing

| Task | Agent | Model |
|------|-------|-------|
| Code review | `swift-code-reviewer` | opus |
| Security audit | `security-auditor` | opus |
| Architecture changes | `code-architect` | opus |
| Simplification | `code-simplifier` | sonnet |
| Test generation | `test-generator` | sonnet |
| Performance analysis | `performance-oracle` | sonnet |
| Bug investigation | `investigate` | sonnet |
| Build validation | `build-validator` | haiku |
| File exploration | Explore agent | haiku |

## Build Commands for Agents

```bash
# Verify build
swift build -c release

# Run tests
swift test

# Build .app bundle
./scripts/build-app.sh

# Relaunch after changes
pkill -f "PortPilot.app"; sleep 1; open ~/Projects/portpilot/build/PortPilot.app
```

## Critical Files (read these first)

| File | Why |
|------|-----|
| `Sources/PortPilotCore/ViewModels/PortStore.swift` | Central state — grouping, search, polling, categorization |
| `Sources/PortPilotCore/Services/LsofScanner.swift` | Primary scanner — async continuation pattern |
| `Sources/PortPilotCore/Services/LibProc.swift` | All unsafe C interop — single isolation point |
| `Sources/PortPilotCore/Services/ProjectResolver.swift` | Cache with NSLock — thread safety critical |
| `Sources/PortPilot/PortPilotApp.swift` | Menu bar setup + lighthouse icon drawing |

## Known Gotchas

1. **`MenuBarExtra` labels only render `Image` and `Text`** — no Canvas, no custom views. The lighthouse icon must be an `NSImage`.
2. **`libproc` `proc_pidinfo(PROC_PIDLISTFDS)` has limited visibility** even for user-owned processes on macOS. That's why `LsofScanner` (setuid root) is primary.
3. **`LsofScanner.runLsof()`** reads pipe data inside `terminationHandler` — safe because `-sTCP:LISTEN` output is well under 64KB pipe buffer. Don't add flags that increase output without addressing this.
4. **`PortStore` is `@MainActor @Observable`** — all access must be on MainActor. Tests use `@MainActor` class annotation.
5. **`ProjectResolver` cache uses `String??`** (double optional) — `nil` = cache miss, `.some(nil)` = cached negative result (no project found).
6. **No Xcode project file** — this is pure SPM. Open `Package.swift` in Xcode if you need the IDE.
7. **`isTemplate` on NSImage** — normal lighthouse is `true` (auto-tints), amber beacon is `false` (keeps orange color). Don't set both to template.

## Concurrency Model

```
App.init() → startPolling()
  └── Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }  // re-check each iteration
          await self.refresh()            // MainActor
            └── LsofScanner.scan()        // background via continuation
            └── ProjectResolver.resolve()  // NSLock-protected cache
          try await Task.sleep(...)       // breaks on cancellation
        }
      }
```

## Test Strategy

- **Integration tests** hit the real system (spawn sockets, spawn processes)
- **Unit tests** use `MockScanner` and canned data
- **No mocking of `libproc`** — tested indirectly via scanner integration
- **No UI tests** — SwiftUI views tested via PortStore state assertions

## v0.2 Priorities

1. Kill result feedback in UI (KillResult is currently discarded in PortRowView)
2. LsofScanner error surfacing (currently silent on failure)
3. Edge case tests for lsof parsing
4. Docker container awareness
5. Global hotkey (Cmd+Shift+P)
