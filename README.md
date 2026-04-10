# Port Pilot

A native macOS menu bar app for managing local dev ports. See what's running, which project owns it, and kill it in two clicks.

## Why

Running 3-5 dev projects means port confusion — "what's on 3000?", "why is 8000 taken?", stale processes after crashes. Port Pilot gives you project-aware port intelligence from the menu bar.

## Features

- **Project detection** — resolves process working directories to project roots (`.git`, `package.json`, `pyproject.toml`)
- **Smart categorization** — separates dev servers (node, python, bun) from macOS apps (Spotify, Figma) by process identity, not just port range
- **Two-click kill** — SIGTERM with confirmation, SIGKILL fallback
- **Conflict detection** — red lighthouse + macOS notification when two processes claim the same port (debounced per-port)
- **Multi-port alerts** — amber highlights when a project has 2+ listening ports, lighthouse beacon glows
- **Grouped views** — by Project or by Type (Dev Servers, Databases, System, macOS Apps)
- **Search** — filter by port number, process name, or project
- **Lightweight** — ~600KB native Swift binary, 2s polling, 5s on low power mode

## Install

Requires macOS 14.0+ and Xcode Command Line Tools.

```bash
git clone https://github.com/kevvykevwin/port-pilot.git
cd port-pilot
./scripts/build-app.sh
open build/PortPilot.app
```

Or copy to Applications:

```bash
cp -r build/PortPilot.app /Applications/
```

## Development

```bash
# Build and run CLI
swift run PortPilot

# Run tests
swift test

# Build .app bundle
./scripts/build-app.sh
```

## Architecture

```
PortPilotCore (library)
├── LsofScanner     — primary scanner (setuid root visibility)
├── PortScanner      — libproc-based fast scanner
├── ProjectResolver  — PID → cwd → project root (LRU cached)
├── PortStore        — @Observable state, search, grouping, polling
└── ProcessKiller    — KillResult enum, graceful termination

PortPilot (app)
├── MenuBarExtra     — lighthouse icon + popover window
├── PortListView     — collapsible grouped sections
└── PortRowView      — port info + kill button + context menu
```

## License

[MIT](LICENSE)
