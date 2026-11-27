# Implicit state machines

Source review of `portpilot` on branch `main`, HEAD `26452243432424ad25e00bde4e9c59f399162834`, 2026-11-27. The model describes the current working-tree control flow, including any local edits; it is documentation, not a runtime refactor or live verification.

## Process termination

[ProcessKiller](../Sources/PortPilotCore/Services/ProcessKiller.swift#L23) has explicit result cases but the request/grace/confirmation lifecycle spans calls.

| From | Event / guard | To |
|---|---|---|
| Observed process | Identity matches PID and expected start time | Send SIGTERM. |
| Observed process | Gone, replaced or identity unavailable | Return corresponding refusal/result; do not signal a different incarnation. |
| SIGTERM accepted | Grace loop sees original incarnation gone/replaced | `terminated`. |
| SIGTERM accepted | Original incarnation still alive at deadline | `forceKillNeeded`. |
| Waiting | Cancellation | Failed termination result. |
| Force-kill requested separately | Identity revalidated | Send SIGKILL; acknowledgment is `signalSent`, not verified exit. |

No automatic escalation connects timeout to SIGKILL. The caller must make a separate force-kill call, and process identity is checked again.

## Managed service recovery

[ManagedRegistry](../Sources/PortPilotCore/Managed/ManagedRegistry.swift#L475) records launch as starting, then [finishLaunch](../Sources/PortPilotCore/Managed/ManagedRegistry.swift#L577) sets service lifecycle to running or needs_review and operation phase to completed or needs_review. A successful launch and an approved disruptive operation are different authorities.

Operation proposal → proposed; approval/denial → authorized/denied only when revision and deadline checks hold. Reroute preparation tracks replacement targets separately from old targets: preparing → ready/fenced → switched/observing → retirement. Restart recovery moves interrupted operations/transitions to needs_review rather than treating incomplete work as completed. See [operation handling](../Sources/PortPilotCore/Managed/ManagedRegistry.swift#L425) and [rerouting](../Sources/PortPilotCore/Managed/ManagedRegistry.swift#L590).

Scope: termination, managed lifecycle, route-health confirmation, and export/notification boundaries. The updater and low-level transport protocols are not exhaustively modeled.

## Route health confirmation

[Serve finding tracker](../Sources/PortPilotCore/Services/ServeRoutes.swift#L265) derives a finding from repeated observations. First dead result → unconfirmed streak; another dead result → increment count and update last-dead time. A finding requires at least two dead observations spanning the configured interval (default 60 seconds). Alive, unknown, or absence from the next evaluated route set drops the streak. Unknown is not dead. This is a derived warning state; it does not remove or rewrite a Tailscale route.

## Export enrollment and notification projection

[ManagedExport](../Sources/PortPilotCore/Managed/ManagedExport.swift#L539) has a separate enrollment machine:

| From | Event and guard | To |
|---|---|---|
| No active/revoked enrollment | User-scope enrollment, explicit consent, valid selection/fields and no recovery/maintenance conflict | Active with a new monotonically increasing epoch and separate read/control credentials. |
| Active | Disable | Revoked, shutdown unconfirmed; persist tombstone before sidecar update. |
| Revoked | Matching registered instance, epoch and shutdown challenge acknowledge | Acknowledged, shutdown confirmed; persist before responding. |
| Revoked | Explicit acknowledge-unconfirmed abandonment | Abandoned; retire credentials without claiming shutdown. |
| Nonactive | Remove agent | Retire credentials; do not change revoked into acknowledged. |

Revocation write failure keeps the in-memory denial and pending revocation, removes credential files, and is retried before later export requests. Re-enrollment is blocked while an active or revoked enrollment remains. Acknowledgment is thus different from credential revocation and from explicit abandonment.

[Notification status](../Sources/PortPilotCore/Managed/ManagedExport.swift#L753) is a projection of an operation and current service identity: proposed/authorized → pending_decision/accepted only while both wall-clock and monotonic deadlines are valid and revision, targets and route generation still match. Expired deadlines project expired; changed service identity projects withdrawn. Execution phases project executing; completed and denied map directly; unrecognized phases project needs_review. A displayed accepted notification is not permission to skip the execution-time guards. Outcome is separately projected as verified, unverified, failed or none; completion alone does not imply verified exit.

## Verification boundary

Source-only review. No application, test suite, remote mutation or deployment was run. The transitions above are scoped to the cited implementation; they do not establish exhaustive coverage of all dependencies or runtime behavior.
