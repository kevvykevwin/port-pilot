# Port Pilot — Progress

> Personal planning notes (specs, plans, reviews, bridge evidence) are gitignored and kept locally; links to them from this log resolve only on the author's machine.

## Pre-release review and P4 publication audit — 2026-11-07

- **History**: rebased the unpushed work onto `origin/main` (dropped a duplicate commit) and rewrote the synthetic fixture literals out of the unpushed history, so every published blob passes the audit.
- **Pre-push review** (Python, Swift, shell/config, cross-model) found and fixed:
  - publication-audit fail-open paths: git replace refs, shallow/grafted history, unreadable artifact directories and files, concatenated tars and zips, zip entries hidden from the central directory or behind a prefix, symlink targets, corrupt xz, file/tree/member names, short object reads, FIFOs, truncated PNG metadata and xattrs; findings redact only the matched value;
  - callers that fail authentication no longer see the global registry revision;
  - a revocation whose tombstone and sidecar writes both fail stays revoked across a helper restart;
  - the updater no longer stops updating once the bundle contains the helper. It checks upstream first, defers only while the helper's launch agent is installed or loaded, and then notifies once per pending version with the supported `managed-helper.py upgrade` path.
- **P4**: the owner signed the manual privacy review; the final audit of the release candidate passes and its receipt verifies.
- **Release-branch review (2026-11-08)** found and fixed three blockers:
  - the zip audit trusted the inflated stream instead of the local header size, so a deflate entry whose header size ran into the next entry could hide a file from the audit while `bsdtar` extracted it;
  - a stopped service with a forked or restarted process tree ended in `needs_review` with no way out; it can now be run again once every recorded process is proven exited;
  - one exited descendant made a live managed service impossible to stop; exited descendants are now pruned and skipped, while the root and any unproven process still fail closed.
  - A second review pass found that pruning used list position to find the root, which is wrong after a reroute; pruning is now off while a route transition exists, a pruned descendant no longer cancels the release timer, and a reroute still requires every recorded process to be live.
  - After rebasing onto the serve-route work, a cross-model review found two more: a failed launch left its started processes running and untracked (they are now stopped with identity-checked signals, and a failed reroute replacement is stopped without touching the old backend), and a leftover helper plist that is not loaded held updates with upgrade steps that cannot work (the notice now says the agent is not loaded and gives load-or-remove steps, or remove-only when the app is missing).
  - Codex also flagged that the updater, while the helper is active, treated a same-version code fix as installed once the clone was current. `build-app.sh` now stamps the bundle's commit into `Contents/Resources/COMMIT`, and the updater counts a release as installed only when that commit is the target and the app can launch. A further Codex report that the CLI dropped `--revision` was checked against the real CLI and is not a bug; a test now covers it.
  - Stopping a failed move's replacement then left the old backend recorded with a dead replacement and an open transition, so the next reconcile marked the still-serving service needs_review with no way to stop it. A failed move whose replacement is proven exited now drops the transition and keeps only the old backend. A second Codex report that `run --port-arg=--port` is always rejected was also checked against the real CLI and is not a bug; a test covers it.
  - The same stuck state still happened when the replacement had forked (its tree can never be verified) or never started, and when a process changed during the switch's first commit; a failed move now always lets the registry drop the transition once every recorded replacement process is proven exited, and the switch rolls its first commit back if an identity check fails. While the helper is active, a bundle without a commit stamp now counts as pending rather than installed, so it gets one notice and picks up the stamp on its next managed upgrade.
  - A stopped or cleaned-up service kept its stable-port relay pointed at the old backend port, so an unrelated process that later bound that port would be served on the stable URL (and any Tailscale route on it). Reconcile now stops the relay of a stopped or removed service, and for every other service keeps the stable port bound but closes connections unless a live recorded process is listening on the backend port (a live launcher alone does not count). Launch and move tasks own the relay while they run; a restart reopens it.
  - The relay also opened at startup before any scan proved the new server owned its port, and stayed open during a move's drain if the new backend died; startup now keeps it closed until each readiness scan proves ownership, and a backend dying during the drain rolls the move back. Agent takeover of the notification shutdown fence treated a failed identity lookup as proof the old agent exited; it now uses the registry's exit rule (different process at the PID, or ESRCH).
  - A helper restart in the middle of a stop, launch or move kept the dead task's fence, so the service stayed needs_review with every decision, quiesce, upgrade and uninstall blocked. Load now marks that operation for review, clears the fence, and keeps any move replacement recorded, so a restart still waits until every recorded process is proven exited. The drain-time rollback now has a real-process regression test (the observation window is injectable for it).
  - The next review round found four more, all fixed with real-process or fake-table tests that fail when the fix is reverted:
    - a move's replacement that exited was never reaped, so as a zombie it could never be proven exited and stop never finished; every child the helper spawned is now reaped until it exits;
    - after a rolled-back move the record held a dead replacement root, so stop refused and the live old backend was unstoppable; stop now skips any proven-exited target (an unreadable one still blocks);
    - a launch whose spawn failed recorded nothing and could never run again; an empty record now counts as finished, since a child is always recorded before it is resumed;
    - during a move's observation and drain only process liveness was checked, so a replacement that closed its listener kept the relay open; ownership of the new port is now re-scanned every second, and a failed move closes the relay until the old backend is proven again.
    - A stop whose signal failed also left needs_review with a fence nothing released; the fence is now released (restart still needs every process proven exited), and a child whose kernel watch cannot be set up is reaped after it is killed.
    - The audit also accepted three more extractor disagreements, now `archive_unreadable`: a zip64 end record and 32-bit end record pointing at different central directories (Apple `unzip` extracted a file `zipfile` never listed), a directory entry carrying data, and a Unicode Path extra (0x7075) naming a different file than the header (`bsdtar` used it).
    - The zip audit also passed a data-descriptor entry whose deflate stream ran past its declared size (`ditto` extracted the hidden bytes); every deflated entry's real CRC and sizes are now checked.
  - Also fixed: option-only CLI calls exit 2 instead of trapping, and a failed managed refresh clears stale associations so the port list's kill buttons work again.
- Deferred review notes (non-blocking): load-time recovery after a helper restart is not committed as events; `managed-helper.py` rollback can stop on a held writer lock or failed bootout, can restore retired export credentials, and leaves the plist after a failed install bootstrap; zip symlink targets are not checked like tar ones; the audit hashes and scans a file through two opens; `listxattr` EPERM is treated as no attributes; the updater re-checks the helper only before building, not before the swap; sealed cursor length grows with global event count; finished moves keep their replacement child (now reaped) in memory for the helper's life; a failed `switchReroute` commit after the relay switch can leave the relay on the new port; a helper killed between spawn and record leaves a suspended, unrecorded orphan (it never runs unless something sends SIGCONT); untested guards: closing the relay during rollback, the ownership re-scan inside the observation window, the empty-live-set stop guard, and the identity-failure kill in `ManagedTrackedChild.init`; a release-pending healthy service is not reused; peer PID/start-time read window; some test rigs skip instead of fail; persistence single read; `publishedBase` accepts any ref; build path remap uses the logical path; helper file-descriptor limit under launchd; checkpoint copies of credentials are never pruned; updater checks helper activity only once before building; the bundle commit stamp is read after the build and counts any tracked change as dirty, while the updater's dirty check is narrower.

## Known gaps closed; P4 dry run — 2026-11-06

- **Export side channel closed**: `notifications.list` no longer returns the global event sequence. It returns an AES-GCM sealed, enrollment-bound `changeCursor` (page schema 2). Page tokens are sealed rather than only signed, and export-actor responses carry revision 0. Mutation-checked: reintroducing the revision, the sequence or a plaintext cursor each fails a test. Residual: a pruned cursor still returns `resyncRequired`, and pruning depends on global event volume.
- **Decompression cap tested**: gzip, bzip2 and xz bombs report `too_large`, and a stream exactly at 64 MiB passes. Removed an unreachable branch; the cap tests are mutation-checked.
- **Audit published base**: a manifest may declare `publishedBase` (ref plus exact sha). Already-public objects are not re-audited; filename policy still applies everywhere.
- **Shipped binaries**: the release build remaps the checkout path and strips debug symbols, so no binary embeds a home path. Signature verifies, and the helper and CLI run.
- Two notification tests were silently skipping. A rejected list call now fails instead of skipping.
- **Verified**: Swift 232 tests (0 failures, 0 skipped after the fix), release build, pytest 22, publication audit 181, final-candidate 33, updater 132, packaging PASS, private agent fixtures 94.
- **P4 dry run** (HEAD `e374461`, fresh app zip, published base `origin/main`): 7 findings. Four are the unsigned manual review. Three are synthetic test fixtures (a fake sentinel and placeholder home paths) inside two unpublished history blobs. The current tree and the app artifact are clean. Clearing the history blobs needs a local history rewrite of unpushed commits, or an explicit fixture allowance; both are user decisions. PC15 keyboard/VoiceOver acceptance is still manual.

## Private-coordination P0 + P1 implemented — 2026-11-06

- **P0 publication audit**: `scripts/audit-publication.py` (manifest + manual review + receipt, hash-pinned candidate/refs/history/artifacts/patterns file; reports category + location only, never matched values). Fixtures: `Tests/shell/test-publication-audit.sh` 120/120, `Tests/shell/test-publication-final-candidate.sh` (P4 mutation invalidation) 30/30. `.gitignore` defense-in-depth entries added.
- **P1 notification contract**: `ManagedExport.swift` adds the `notification_read` / `export_control` actors in a versioned sidecar (`export-state.json`; legacy `actors.json` untouched), `notifications.list` allowlisted projection with HMAC refs, epoch-bound authenticated page tokens, replacement-only consent, control-only shutdown acknowledgement bound to the registered agent instance, revocation tombstones, `PortPilotHelper --capabilities`, and helper-replacement preflight in `managed-helper.py`. UI: `ManagedExportView.swift` (default off).
- **Review**: opus structural review found 3 P1s (non-durable disable, fixed agent instance, compressed archives escaping audit) + P2s; all fixed. Mutation-checked the two P1 regression tests (each fails when its fix is reverted).
- **Verified 2026-11-06**: `swift test` 217 tests, 0 failures; `swift build -c release` ok; pytest `test_managed_helper.py` 22 passed; `test-auto-update.sh` 132 passed; `test-managed-packaging.sh` PASS; `git diff --check` clean.
- **Open**: PC15 manual keyboard/VoiceOver acceptance (view compiled only, never opened). `highWaterMark` is the global event sequence (reveals activity volume on unselected services — deferred). Decompression-bomb cap path untested. P2/P3 blocked on a confirmed private workspace; P0 evidence move blocked on a confirmed private destination. P4 needs the final candidate, a manual privacy review and protected receipt paths. Audit flagged personal paths/bridge details in DevDocs notes, `plans/`, specs, some sources/tests and `scripts/inspect-t3-permissions.cjs` — manual review required before any publication.
- Nothing committed, installed, released or pushed.
- **Helper-verified agent takeover (2026-11-06, user decision)**: a restarted agent may confirm shutdown after disable only when the helper proves the previously registered agent process has exited. The helper uses the kernel peer PID (`LOCAL_PEERPID`) plus process start time, recorded at each control poll. A live predecessor, or a registration with no recorded process, keeps the fence unconfirmed. Spec "Revocation fence" plus 2 edge cases and 1 test case were amended. `swift test` 226/0, private fixtures 90/0. Live end-to-end on a temporary state directory (real debug helper, real CLI-launched service, real agent, fake inbox):
  - one coalesced message ("Service 1: Stop request needs your decision…")
  - no path, name, actor, address, port or PID in the delivered bytes
  - disable led to a confirmed acknowledgement with zero sends after the fence
  - a hung real predecessor process blocked takeover; after it was killed, the successor took over and confirmed (`agentTakeover` true), with zero sends
- **P2 (private, 2026-11-06)**: user confirmed the private workspace as a sibling repo outside this tree. The notification agent there passes 85 fixture tests against a fake helper and a fake receiver. The real Unix-socket transport was smoke-tested against a real debug helper using a temporary state directory: the framing round-trips, and forged export credentials and the user credential calling `notifications.list` are refused. A full real-helper enrollment run has not been done, because it needs a registered service. There is no provider adapter or live delivery. The private evidence destination is still unconfirmed.

## Fresh plan review amendments applied — 2026-11-05

- Applied all five findings from the fresh BIG review: replacement consent on recipient/selection changes, control-only shutdown acknowledgement, compatible optional enrollment storage, bounded full-outbox recovery and an actual final-candidate publication audit.
- Added PC16–PC20 and eleven mapped acceptance cases; updated implementation ownership and the XML final publication gate. Review verdict is READY for scoped implementation/fixtures, with existing live gates retained. Documentation-only changes; runtime acceptance remains unexecuted.

## Existing bridge reconciliation — 2026-11-05

- Reconciled the private-coordination and writer specs, component map and XML plan with the located private T3 bridge. Reuse its verified behavior before duplicating a connector; preserve detailed operational evidence outside this public project.
- Split connection-created and desk-thread acceptance, separated orchestration/authoring/service-control authority, and added WC13–WC15 with seven bridge compatibility cases. Human approval, exact owner acknowledgement and provider-selection enforcement remain explicit gates.
- Documentation-only update. The prior setup record supplies historical live evidence; no new live tests, credential changes, thread creation, bridge reconfiguration or implementation performed.

## Optional private coordination and writer specification — 2026-11-03

- Added `spec-portpilot-private-coordination.md`, `spec-portpilot-write-container.md`, `DevDocs/coordination-component-map.md` and an XML execution companion. Public product remains independent; personal adapter/configuration belong in a separate private project and secrets outside both repositories. Initial integration is notification-only with local decisions.
- BIG `/plan-review --apply all` completed with six amendments: publication coverage, coherent snapshots, revocation fences, bounded uncertain delivery, helper-enforced authority and durable grant/replay recovery. Report: `DevDocs/plan-review-private-coordination.md`.
- Writer exploration begins with synthetic queue/connector/helper/issuer fixtures; packaging remains undecided. Live owner/user channels and write stages require their own evidence and enrollment. Documentation-only work: no runtime tests rerun, no live setup, file migration, credential issuance, message, publication or deployment. Existing implementation acceptance gaps remain open.

## Current State

**Version**: v0.5.0 (build 4) in `VERSION`, bumped 2026-11-06 for the managed-servers helper, CLI and notification export. Prepared for the `v0.5.0` release after the P4 audit (2026-11-07).
**Tests**: `swift test` — 147 tests, zero failures (12.118 s), verified 2026-11-03; `/tmp/portpilot-20261103-tests.log`. Two identity regressions failed before the fix and pass now. T3 source-policy audit: nine checks passed. Updater/packaging shell evidence remains from 2026-11-02.
**Build**: `swift build -c release` succeeded on 2026-11-03 (20.19 s); `/tmp/portpilot-20261103-release.log`. The app bundle/signature checks are from November 2 and were not regenerated for the newer source. Nothing installed or deployed.
**Managed-server status**: In progress; P1/P2 are not accepted. The new ownership panel has build evidence only, without fresh screen, keyboard or VoiceOver acceptance.
**GUI verification**: PARTIAL (historical reliability UI only). SwiftUI seed-window screenshots were inspected (`/tmp/portpilot-project-window.png`, `/tmp/portpilot-type-window.png`) for layout, category labels, the expected-services checkmark, and the fallback freshness footer. Not verified: the installed menu bar app's interactions and kill flows (Sent vs Stopped). Do not treat the reliability work as verified in the running app.
**Working tree**: committed for the v0.5.0 release; personal planning notes stay gitignored.
**Repo**: https://github.com/kevvykevwin/port-pilot

## Last Action

2026-11-08: Added Tailscale Serve broken-link findings on `feat/serve-routes`. Port Pilot reads `tailscale serve status --json` (at most every 30 s, only with an injected reader), loopback-probes routes the scan cannot match, confirms after two dead checks at least 60 s apart, and shows a plain-language banner, a row badge and a Copy fix button. It never changes Tailscale config. Owner check (Tailscale 1.104.4): a bare `serve --https=<port> off` deletes every handler on the port, while `--set-path=/ off` removes only `/`, so web-route fixes always name their path. `ProcessClassifier.terminationBlockReason` replaces the kill button with a lock for Tailscale's IPNExtension and macOS ControlCenter (AirPlay Receiver), which macOS relaunches. `swift test`: 230 tests, 0 failures. GUI reviewed by the owner in the running app; the PR screenshot uses seed data.

2026-11-03: Verified the installed T3 0.1.6 authorization path and saved reproducible source-policy evidence. No message-only permission exists in the inspected build; prepared an unsent typed-coordination integration request in `DevDocs/t3-coordination-permissions.md`. Fixed stale process identity acceptance in claim/keep and cleanup's pre-fence/signal checks. Full tests and release build pass; broader feature acceptance remains open.

2026-11-02: Implemented and tested a local managed-server foundation. The full coordination contract remains incomplete. See [implementation checkpoint](managed-servers-implementation.md) for supported behavior, development commands, evidence and remaining work. Helper/CLI, authenticated IPC, durable registry, direct-child launch, healthy reuse, adoption, explicit stop decisions, bounded forwarding and a basic native ownership panel are present. Arbitrary descendant supervision, automatic cleanup enablement, launch-agent lifecycle transactions, full reroute orchestration and live bot/Tailscale acceptance are not complete. No installation, startup-agent changes, PR, commit, push or deployment occurred.

Previous reliability work:

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

## Ownership exploration — 2026-11-02

- Agreed scope: show all listeners, but initially automate only explicitly registered servers. Existing or manually launched servers remain visible and may be explicitly adopted; inferred ownership alone does not authorize automatic cleanup. Cleanup eligibility and integration design remain under discussion; no runtime changes implemented.
- Agreed cleanup eligibility: a registered server may stop automatically only after every owning thread explicitly releases it and a short grace period passes, provided no user "Keep running" override or new owner claim exists. Thread completion, inactivity, and missing heartbeats trigger review rather than automatic shutdown. Grace duration remains undecided.
- User prefers exploring coordinated rerouting, including local and Tailscale access, rather than pinning shared previews to their current backend ports. Stable user-facing addresses, routing integration, consumer updates, recovery behavior, and launch-wrapper adoption remain undecided; this is design direction, not authorization to move running services.
- Agreed address behavior: managed previews have stable user-facing addresses while their underlying server ports may change. This resolves the address-stability question above; address identity, routing implementation, and migration/recovery details remain open.
- Agreed preview identity: checkout/worktree plus service, independent of T3 thread identity. Multiple threads may claim the same service; distinct worktrees and distinct services receive separate preview identities. Concrete address format remains undecided.
- Agreed coordinator scope: the coordination bot may automatically contact owning T3 threads, including waking idle threads, to identify needed registered servers, request explicit release of unused ones, and coordinate rerouting. Requests must stay within server management; unrelated development and automatic thread archival are excluded. No response leaves the server running and flagged for review. This approves the proposed feature behavior; no messages sent during this design session.
- Agreed rerouting authority: after every owner agrees to a move, PortPilot may execute it automatically when it can verify the replacement before switching the stable address and recover from a failed switch. the coordination bot must flag unclear cases for the user's decision; moves requiring the existing server to stop before replacement verification require a user decision. Uncertainty or silence does not authorize a move.
- Agreed review triggers: event-driven checks plus a periodic backstop. Proposed events include an occupied port during managed launch, explicit owner release, and thread completion; completion triggers ownership review, never automatic release. Periodic cadence and event integration remain to be specified; repeated unresolved cases should not generate duplicate notifications. No schedule or background worker created.
- User wants decisions brought to their attention through the coordination bot and offered to create a dedicated coding bot for this purpose. Proposed responsibility split: the bot coordinates owners and user decisions; PortPilot verifies and executes process/routing actions under the agreed rules. Bot interface, runtime, and integration remain undecided; no bot created.
- User subsequently created the dedicated bot and chose an existing chat-bot interface for interaction and decisions; runtime integration still needs verification.
- Agreed reuse rule: reuse only compatible launch configurations within the same checkout/worktree and service. Incompatible configurations get named variants with separate stable preview addresses; never silently replace a preview another thread is using. Separate processes in one checkout do not isolate source-file changes; simultaneous source versions require separate checkouts or immutable artifacts.

## Managed-server specification — 2026-11-02

- Wrote `spec-portpilot-coordination.md` plus ownership, routing and bot child specs: 39 acceptance criteria, 75 mapped test-case rows, and 36 edge-case scenarios. This is a proposed implementation contract, not implemented behavior.
- Ran BIG `/plan-review` in report-only mode; report: `DevDocs/plan-review-portpilot-coordination.md`. Verdict: READY WITH AMENDMENTS. Four amendments cover execution fencing, helper upgrade/child survival, Tailscale configuration concurrency, and socket framing/resource limits. Initial amendments were not applied in that pass; the follow-up below supersedes that status.
- Implementation remains in this PortPilot coding thread; the coordination bot supplies integration discovery/review and will deliver user decisions through its existing interface. Bot access/user-response proof and installed Tailscale capabilities remain live-integration gates. No app tests, process signals, thread messages, routing changes, installation or deployment performed in this specification pass.

## Managed-server review amendments applied — 2026-11-02

- Re-ran BIG `/plan-review --apply`; amended the common contract and all three child specs. Applied execution fencing, helper upgrade/recovery, user-mediated v1 Tailscale setup/removal, and bounded socket framing, plus clock/configuration regression coverage.
- Re-reviewed verdict: READY for staged implementation; no outstanding plan amendments. The specs now have 40 acceptance criteria and 104 test-case rows. Updated review: `DevDocs/plan-review-portpilot-coordination.md`.
- Automatic backend rerouting remains in scope; automatic Tailscale configuration writes are deferred beyond v1. Bot/T3 authentication, helper child survival and remote acceptance remain explicit implementation gates. Documentation only; no runtime changes or app tests.

## Deploy Log

### 2026-11-08 01:23 — feat/serve-routes (full)
<!-- deploy:bfed8cc-1794066829-ViSIMm -->
- Files: 20 changed (`Sources/ (11), Tests/ (6), (root) (3)`)
  - `CLAUDE.md`
  - `Sources/PortPilot/PortPilotApp.swift`
  - `Sources/PortPilot/Views/MenuBarView.swift`
  - `Sources/PortPilot/Views/PortListView.swift`
  - `Sources/PortPilot/Views/PortRowView.swift`
  - `Sources/PortPilot/Views/ServeFindingsBanner.swift`
  - `Sources/PortPilotCore/Services/BackendLiveness.swift`
  - `Sources/PortPilotCore/Services/LoopbackProbe.swift`
  - `Sources/PortPilotCore/Services/ProcessClassifier.swift`
  - `Sources/PortPilotCore/Services/ServeRoutes.swift`
  - `Sources/PortPilotCore/Services/ServeStatusReading.swift`
  - `Sources/PortPilotCore/ViewModels/PortStore.swift`
  - `Tests/PortPilotTests/LoopbackProbeTests.swift`
  - `Tests/PortPilotTests/ProcessClassificationTests.swift`
  - `Tests/PortPilotTests/ServeRouteStoreTests.swift`
  - +5 more
- Commits ahead of origin/main (2):
  - docs: record serve-route findings and the no-kill rule
  - feat: flag broken Tailscale links and stop offering kills that cannot work

### 2026-11-06 23:20 — main (hotfix)
<!-- deploy:d9068df-1793974790-V1w5mc -->
- Files: 50 changed (`Sources/ (23), Tests/ (19), (root) (4), scripts/ (4)`)
  - `.gitignore`
  - `CLAUDE.md`
  - `Package.swift`
  - `Sources/PortPilot/Views/ManagedExportView.swift`
  - `Sources/PortPilot/Views/ManagedServicesView.swift`
  - `Sources/PortPilot/Views/MenuBarView.swift`
  - `Sources/PortPilot/Views/PortListView.swift`
  - `Sources/PortPilot/Views/PortRowView.swift`
  - `Sources/PortPilotCLI/main.swift`
  - `Sources/PortPilotCore/Managed/ManagedAncestry.swift`
  - `Sources/PortPilotCore/Managed/ManagedClient.swift`
  - `Sources/PortPilotCore/Managed/ManagedExport.swift`
  - `Sources/PortPilotCore/Managed/ManagedForwarder.swift`
  - `Sources/PortPilotCore/Managed/ManagedIPC.swift`
  - `Sources/PortPilotCore/Managed/ManagedLaunch.swift`
  - +35 more
- Commits ahead of origin/main (8):
  - chore: bump version to 0.5.0 (build 4)
  - fix: keep the builder's home path out of shipped binaries
  - fix: stop export responses revealing activity on unselected services
  - feat: let the publication audit skip already-public history
  - feat: add managed servers helper and private notification contract
  - feat: add publication audit for release candidates
  - docs: point CLAUDE.md learnings at the central dev-journal log
  - chore: keep personal planning notes and bridge evidence out of git

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

## Managed-server local foundation — 2026-11-02

- Added helper/CLI targets and private, singleton state; framed authenticated IPC; revision/fence policy, durable replay and events; direct-child readiness and adoption; explicit user-approved stop/force operations; stable loopback byte-stream forwarding; a helper-offline-safe ownership panel.
- Real fixtures verified disconnected-client replay, compatible reuse without another child, HTTP 10 MiB streaming, incremental SSE, WebSocket echo, per-connection backend generations, stable-port collision rejection, and foreground helper restart preserving child/claims/port. Restart remains `needs_review`; this does not prove launchd upgrade behavior or complete descendant supervision.
- Final Swift suite: 145 tests, zero failures. Updater suite: 132 assertions, zero failures. Managed packaging fixture passed. Evidence and unimplemented criteria: `DevDocs/managed-servers-implementation.md`.
- Tailscale read-only inventory found app-bundled CLI version 1.104.4 and three existing HTTPS selectors. No routes adopted or changed. Coordination-bot authentication evidence and a second tailnet device remain requested integration inputs.
- Next: finish descendant lifecycle and cleanup supervision, then installer/upgrade recovery; complete reroute transactions, UI acceptance and the gated integrations. The unattended updater deliberately defers replacement of helper-bearing installations until the lifecycle transaction is verified.

## Coordination-bot evidence and remote acceptance device — 2026-11-03

- The user supplied setup screenshots reporting successful read-only T3 MCP access from the coordination bot over the tailnet. The separate write probe reportedly passed its scope check but failed the runtime-mode boundary (`approval-required` caller versus `full-access` target threads). This is user-supplied report evidence, not a new live or source verification.
- P4 still needs a supported scoped owner-messaging path and proof that user-decision callbacks represent the user rather than model output. Runtime/adapter code location, read-only write-denial enforcement, ACL restriction and bot-host restart recovery remain unverified. No permission expansion, token revocation, remote message or configuration change was performed.
- The user selected a second device for second-device Tailscale preview acceptance. Record the Safari/tailnet check against the eventual enrolled endpoint with URLs, operation ID, revision and time; remote acceptance remains pending.
- Updated `DevDocs/managed-servers-implementation.md`. Documentation-only update; no code changes or test reruns. Previous implementation gaps remain open.

## T3 permission investigation and identity checks — 2026-11-03

- Reviewed the installed bundled authorization code, not only the screenshots. Source SHA-256 and locators are preserved in `Tests/fixtures/t3-permissions-0.1.6.json`; regenerate with `scripts/inspect-t3-permissions.cjs` under the installed app's Electron runtime. Nine pure-policy checks and source-wiring assertions passed. No credentials were read or issued and no live write probe was performed.
- Confirmed the common rename/send runtime guard, CLI default ceiling, narrowing-only mode header and absence of a message-only scope. Wrote a proposed typed service-coordination inbox request, not sent externally. the coordination bot stays read-only; real-user callback authentication remains unverified.
- New regression tests exposed claim success on reused/missing incarnations before polling and cleanup invoking its signal callback without a registry-side identity check. Added checks before claim/keep commit, before cleanup fencing and before signal dispatch; uncertainty retains ownership and enters review without a signal.
- Verification: 147 Swift tests passed; release build passed. No fresh app bundle, installation, release, PR or deployment. Next implementation work remains descendant supervision and helper lifecycle recovery; live coordination needs the reviewed T3 integration capability and authenticated callbacks.

## Managed lifecycle, reroute and kernel supervision — 2026-11-03

- Added suspended spawning with a kernel fork/exit watch before user code runs. Real fixtures verify that a child cannot execute early and that even an already-exited fork permanently invalidates completeness. Automatic release cleanup now operates only with current kernel proof, a full 60-second grace and fresh identities. Forked, adopted and restarted trees remain review cases. A stopped compatible service can restart with the same ID/address and a higher generation.
- Added encrypted restart recipes, separate private secret references, explicit environment port injection, bounded configuration reads and Git-worktree metadata identity. Missing or changed inputs prevent reuse/relaunch.
- Implemented parallel-safe reroute preparation, revision/owner fencing, readiness, cutover, 30-second observation, bounded drain, healthy rollback and verified old-tree retirement. The real fixture preserves claims and the stable URL, reaches the new backend, and verifies old exit. Unknown trees/undrained streams stay for review rather than being reported as stopped.
- Replaced Network.framework forwarding after reproducing loopback ENETDOWN with healthy backends. Nonblocking BSD relay tests cover generation pinning, 10 MiB HTTP, SSE, WebSocket, restart rebinding, 100 routes and 200 connections. Fixed an exit-observation race: identity lookup failure alone cannot complete retirement before ESRCH/reuse evidence.
- Added shared GUI decision controls and incarnation-based listener role labels; managed rows direct termination through helper decisions. Added read-only Tailscale selector enrollment and drift checks. No live route was adopted or changed.
- Added an explicit launch-agent lifecycle utility with quiescence/checkpoint, same-schema replacement/rollback, shared enrollment/update locking and an uncertain-resume commit boundary that forbids rollback over possibly accepted claims. Ten isolated installer tests passed; active children still defer upgrades and unattended updates remain disabled for helper-bearing installations. Actual launchd acceptance remains open.
- Current full Swift suite after the final child-reaping guard: **164 tests, zero failures** (58.686 seconds), `/tmp/portpilot-20261103-verified-tests.log`. Updater: **132 assertions, zero failures**; 10 lifecycle tests and the managed packaging fixture passed. Final release build/app packaging and deep strict signature verification passed; packaged helper/CLI both read version 0.4.0. Evidence: `DevDocs/managed-servers-implementation.md`.
- Full-spec gaps remain explicit in that checkpoint: interruption/recovery and installer fault matrices, bind retry/relocation handling, framework/hot-reload and native accessibility acceptance, second-device remote acceptance, and the gated coordination-bot integration. No installation, deployment, PR, live startup change or external message occurred.
