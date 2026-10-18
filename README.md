# Port Pilot

A native macOS menu bar app for managing local dev ports. See what's running, which project owns it, and kill it in two clicks.

The current version is whatever the [`VERSION`](VERSION) file says on the branch you have checked out — that file is the single source of truth for the bundle version and the release tag.

## Why

Running 3-5 dev projects means port confusion — "what's on 3000?", "why is 8000 taken?", stale processes after crashes. Port Pilot gives you project-aware port intelligence from the menu bar.

## Features

- **Project detection** — resolves process working directories to full project roots (`.git`, `package.json`, `pyproject.toml`) without merging equal directory names
- **Local process catalog** — identifies databases, proxies, tunnels, editor services, macOS apps, and dev runtimes from executable/script context; unfamiliar processes remain Unknown
- **Safe two-click kill** — confirms process identity before SIGTERM, waits for exit, and offers a separately confirmed SIGKILL only when needed
- **Resilient scanning** — uses `lsof` for broad visibility and falls back to `libproc` when the primary scanner fails, while retaining the last healthy result if both are unavailable
- **Overlapping listeners** — red lighthouse + debounced notification for overlapping TCP bindings; preserves every IPv4/IPv6 address for analysis
- **Project service review** — amber highlights for unreviewed multi-service projects or unexpected services; save expected services per project
- **Grouped views** — by Project or by Type, with explanations and saved category overrides
- **Search** — filter by port number, process name, or project
- **Bounded polling** — waits 2s while the menu is open, 30s in the background, or 60s in background Low Power Mode after each scan; overlapping refreshes share one scan, with a 5s lsof timeout and 4 MiB output cap

### Categories, expected services, and freshness

Right-click a process row to see why it was categorized and its address bindings.
Choose **Category for This Process** to save a local override, or **Use Automatic
Category** to remove it. Runtime overrides require a script or project context so
labeling one Node service does not relabel every Node process. Rules describe a
process; they never bypass termination identity checks.

Right-click a project heading to **Remember Current Services as Expected**. This
suppresses the amber review indicator for that project's normal service set,
including process restarts. New executables/scripts/ports and duplicate instances
still flag for review. **Clear Expected Services** removes the baseline. These
choices persist locally in the app's preferences, keyed by full project root.

The footer shows the last successful scan age and whether the fallback scanner
was used. Both scanners are limited by process visibility. Scan failures retain
the previous data and its timestamp. Overlapping listeners are observations, not
proof that another server failed to bind. Port Pilot cannot see failed bind
attempts or prove that a port is free for every possible address-family setup.
A force-kill acknowledgment says **Sent**; only a verified graceful exit says
**Stopped**. The next scan removes processes that have exited.

No model or network service is used for categorization. Executable names and paths
are descriptive evidence, not verified code signatures. Unsupported runtime launch
forms (such as inline code or interpreter switches) can remain ambiguous; label
those by project context or leave them Unknown.

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
./scripts/auto-update.sh --dry-run       # show what it would do (fetches; installs nothing)
./scripts/auto-update.sh                 # update now if anything changed
./scripts/install-auto-update.sh         # check every 6h + at login (launchd)
./scripts/install-auto-update.sh --status
./scripts/install-auto-update.sh --uninstall
```

It only ever installs a commit that is on `origin/main`, and refuses to run when you
have uncommitted changes to build inputs, unpushed commits on `main`, a `main` that has
diverged from `origin/main`, or a feature branch checked out — so it never installs
unreviewed work or overwrites work in progress. `--force` overrides those refusals.

Every failure path leaves a launchable app installed: it builds and tests before
uninstalling anything, stages the new bundle beside the target and swaps it in with an
atomic rename, verifies the app actually starts, and otherwise rolls back — including
when interrupted by a signal mid-install. A commit that installs but will not launch is
recorded and not retried, so a bad build cannot quit and replace your app every six
hours. Logs land in `~/Library/Logs/PortPilot/auto-update.log`, and failures also raise
a desktop notification.

## Development

```bash
# Build and run CLI
swift run PortPilot

# Run tests
swift test

# Tests for the install/update scripts (sandboxed; no Swift build, no real install)
./Tests/shell/test-auto-update.sh

# Build .app bundle
./scripts/build-app.sh
```

## Architecture

```
PortPilotCore (library)
├── ResilientPortScanner — lsof primary + libproc fallback
├── ProjectResolver      — PID → cwd → full project-root identity (bounded cache)
├── ConflictDetector     — address-aware TCP listener conflicts
├── PortStore            — coalesced scans, binding-preserving snapshots, grouping, local preferences
└── ProcessKiller        — PID-identity-safe graceful/forced termination

PortPilot (app)
├── MenuBarExtra     — lighthouse icon + popover window
├── ConflictNotifier — debounced macOS notifications
├── PortListView     — collapsible grouped sections
└── PortRowView      — port info + kill button + context menu
```

## License

[MIT](LICENSE)
