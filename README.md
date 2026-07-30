# Port Pilot

A native macOS menu bar app for managing local dev ports. See what's running, which project owns it, and kill it in two clicks.

Current app version: **0.4.0** (build 3).

## Why

Running 3-5 dev projects means port confusion — "what's on 3000?", "why is 8000 taken?", stale processes after crashes. Port Pilot gives you project-aware port intelligence from the menu bar.

## Features

- **Project detection** — resolves process working directories to full project roots (`.git`, `package.json`, `pyproject.toml`) without merging equal directory names
- **Smart categorization** — separates dev servers (node, python, bun) from macOS apps (Spotify, Figma) by process identity, not just port range
- **Safe two-click kill** — confirms process identity before SIGTERM, waits for exit, and offers a separately confirmed SIGKILL only when needed
- **Resilient scanning** — uses `lsof` for broad visibility and falls back to `libproc` when the primary scanner fails, while retaining the last healthy result if both are unavailable
- **Conflict detection** — red lighthouse + macOS notification when overlapping TCP listeners claim the same address and port (debounced per-port)
- **Multi-port alerts** — amber highlights when a project has 2+ listening ports, lighthouse beacon glows
- **Grouped views** — by Project or by Type (Dev Servers, Databases, System, macOS Apps)
- **Search** — filter by port number, process name, or project
- **Adaptive polling** — refreshes every 2s while the menu is open, every 30s in the background, and every 60s in background Low Power Mode

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
├── ResilientPortScanner — lsof primary + libproc fallback
├── ProjectResolver      — PID → cwd → full project-root identity (LRU cached)
├── ConflictDetector     — address-aware TCP listener conflicts
├── PortStore            — serialized publication, search, grouping, adaptive polling
└── ProcessKiller        — PID-identity-safe graceful/forced termination

PortPilot (app)
├── MenuBarExtra     — lighthouse icon + popover window
├── ConflictNotifier — debounced macOS notifications
├── PortListView     — collapsible grouped sections
└── PortRowView      — port info + kill button + context menu
```

## License

[MIT](LICENSE)
