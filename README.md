# Port Pilot

A native macOS menu bar app for managing local dev ports. See what's running, which project owns it, and kill it in two clicks.

The current version is whatever the [`VERSION`](VERSION) file says on the branch you have checked out — that file is the single source of truth for the bundle version and the release tag.

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

**Port Pilot is installed by building it from source. There is no downloadable
`.app`, `.dmg`, or installer, and the Releases page intentionally ships no binaries.**

Requires macOS 14.0+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/kevvykevwin/port-pilot.git
cd port-pilot
./scripts/build-app.sh
cp -R build/PortPilot.app /Applications/
open /Applications/PortPilot.app
```

Port Pilot is a menu bar app with no dock icon (`LSUIElement`), so look for the
lighthouse in your menu bar rather than a window.

### Why source-only?

The build is signed **ad hoc** (`codesign -s -`), not with a paid Apple Developer ID,
and it is not notarized. An ad-hoc signature is valid on the machine that produced it,
but macOS Gatekeeper blocks the same bundle after it has been downloaded from the
internet — you'd get *"Port Pilot is damaged and can't be opened"* or an unidentified-developer
refusal. Rather than publish binaries that greet you with a scary, misleading error and
ask you to run `xattr -d com.apple.quarantine` on them, the project ships source you
compile locally. Building takes about 20 seconds.

## Versioning

- [`VERSION`](VERSION) is the single source of truth. `scripts/build-app.sh` reads it to
  stamp `Info.plist`; `scripts/release.sh` reads it to create the `v<version>` git tag.
- Git tags mark released versions. Releases carry notes only — no binary assets, per above.
- `main` is the development branch and may sit ahead of the newest tag. To build a specific
  release, `git checkout v0.4.0` before running `./scripts/build-app.sh`.

## Staying up to date

Because installs are built locally, updating means rebuilding. `scripts/auto-update.sh`
automates that — it fast-forwards `main`, rebuilds, runs the tests, and reinstalls to
`/Applications` only if the build and tests pass, keeping a backup to roll back to.

```bash
./scripts/auto-update.sh --dry-run       # show what it would do
./scripts/auto-update.sh                 # update now if anything changed
./scripts/install-auto-update.sh         # check every 6h + at login (launchd)
./scripts/install-auto-update.sh --status
./scripts/install-auto-update.sh --uninstall
```

It refuses to run when you have uncommitted changes to build inputs, when `main` has
diverged from `origin/main`, or when you're on a feature branch — so it never overwrites
work in progress. Logs land in `~/Library/Logs/PortPilot/auto-update.log`.

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
