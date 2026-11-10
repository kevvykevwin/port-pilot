import Foundation
import Darwin

/// All policy decisions and final synchronous effects run on this actor. Network
/// readiness waits must happen outside the actor, followed by a revision check.
public actor ManagedRegistry {
    // Internal (not private) so the export extension in ManagedExport.swift can use them.
    let persistence: ManagedPersistence
    var state: ManagedState
    let actors: [ManagedActor]
    var recoveryRequired = false
    /// Optional export sidecar (export-state.json). Independent of registry.json and actors.json.
    var exportBook = ManagedExportBook()
    /// Non-nil when the sidecar is unsupported or corrupt: every export operation fails closed.
    var exportFault: ManagedError?
    /// True while a revocation exists only in memory (or only in a tombstone). Every export request first
    /// tries to persist it and fails with `.recoveryRequired` until that succeeds.
    var exportRevocationPending = false
    /// Random per registry instance; page tokens issued before a helper restart are invalid.
    let exportBootNonce = ManagedExportStore.randomHex(16)
    private var releaseTimes: [UUID: TimeInterval] = [:]
    let uptime: @Sendable () -> TimeInterval
    let now: @Sendable () -> Date
    private var signalTimes: [UUID: TimeInterval] = [:]
    var approvalDeadlines: [UUID: TimeInterval] = [:]
    let identity: @Sendable (Int32) -> ManagedIncarnation?
    private let sendSignal: @Sendable (ManagedIncarnation, Bool) -> Bool
    /// True only when the OS confirms the PID no longer exists (ESRCH). Injectable for tests.
    private let isGone: @Sendable (Int32) -> Bool
    private var lastWallTime: Date

    public init(persistence: ManagedPersistence, actors: [ManagedActor],
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                now: @escaping @Sendable () -> Date = { Date() },
                identity: @escaping @Sendable (Int32) -> ManagedIncarnation? = ManagedProcess.incarnation,
                sendSignal: @escaping @Sendable (ManagedIncarnation, Bool) -> Bool = { target, force in
                    guard ManagedProcess.incarnation(pid: target.pid) == target else { return false }
                    let result = force ? ProcessKiller.forceKill(pid: target.pid, expectedStartTime: target.startTime)
                                       : ProcessKiller.terminate(pid: target.pid, expectedStartTime: target.startTime)
                    return result == .signalSent
                },
                isGone: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) != 0 && errno == ESRCH }) {
        self.persistence = persistence; self.actors = actors; self.uptime = uptime; self.now = now; self.isGone = isGone
        lastWallTime = now(); self.identity = identity; self.sendSignal = sendSignal
        do {
            state = try persistence.load()
            // Restart invalidates all approvals. Uncertain external effects need
            // reconciliation, never replay. No cleanup timer survives a restart.
            for i in state.operations.indices { state.operations[i].approved = false }
            for i in state.services.indices where state.services[i].lifecycle != "stopped" {
                state.services[i].lifecycle = "needs_review"
                state.services[i].treeComplete = false
                // The task that held the fence died with the old helper and can never release it.
                // Record the interrupted operation for review and keep every process it may have
                // started, so restart still requires each one proven exited.
                if let fence = state.services[i].fence {
                    if let o = state.operations.firstIndex(where: { $0.id == fence }) {
                        state.operations[o].phase = "needs_review"
                        state.operations[o].outcome = "helper_restarted_outcome_unverified"
                    }
                    state.services[i].fence = nil
                }
                if let transition = state.services[i].transition {
                    for target in transition.newTargets where !state.services[i].incarnations.contains(target) {
                        state.services[i].incarnations.append(target)
                    }
                    state.services[i].transition?.phase = "needs_review"
                    if let o = state.operations.firstIndex(where: { $0.id == transition.operationId }),
                       !["completed", "needs_review", "denied"].contains(state.operations[o].phase) {
                        state.operations[o].phase = "needs_review"
                        state.operations[o].outcome = "helper_restarted_outcome_unverified"
                    }
                }
            }
        } catch { state = ManagedState(); recoveryRequired = true }
        (exportBook, exportFault, exportRevocationPending) = ManagedExportStore.load(persistence)
    }
    public func preflight(_ request: ManagedRequest) -> ManagedResponse? {
        do {
            guard request.protocolVersion == 1 else { throw ManagedError.protocolMismatch }
            guard let actor = actors.first(where: { $0.id == request.actor }),
                  actor.credentialHash == ManagedDigest.hash(Data(request.credential.utf8)) else { throw ManagedError.unauthorized }
            if now() < lastWallTime {
                for i in state.operations.indices { state.operations[i].approved = false }
                approvalDeadlines.removeAll()
            }
            lastWallTime = now()
            guard !recoveryRequired else { throw ManagedError.recoveryRequired }
            guard state.maintenance == nil else { throw ManagedError.operationInProgress }
            if request.operation == "service.run", actor.scope != .owner && actor.scope != .user { throw ManagedError.unauthorized }
            if request.operation == "service.adopt", actor.scope != .user { throw ManagedError.unauthorized }
            if request.operation == "tailnet.enroll", actor.scope != .user { throw ManagedError.unauthorized }
            if let previous = state.replays[request.requestId] {
                guard previous.actor == actor.id else { throw ManagedError.unauthorized }
                guard previous.digest == ManagedDigest.hash(try ManagedDigest.canonical(request)) else { throw ManagedError.idempotencyConflict }
                return previous.response
            }
            return nil
        } catch { return ManagedResponse(requestId: request.requestId, error: error as? ManagedError ?? .invalidInput) }
    }

    public func reuseLaunch(_ request: ManagedRequest, serviceId: UUID, fingerprint: String) throws -> ManagedResponse {
        if let previous = preflight(request) { return previous }
        guard actors.contains(where: { $0.id == request.actor && ($0.scope == .owner || $0.scope == .user) }) else { throw ManagedError.unauthorized }
        guard let i = state.services.firstIndex(where: { $0.id == serviceId }) else { throw ManagedError.invalidInput }
        let service = state.services[i]; try checkRevision(request, service)
        guard ["running", "release_pending"].contains(service.lifecycle), !service.launchFingerprint.isEmpty,
              service.launchFingerprint == fingerprint else { throw ManagedError.incompatibleLaunch }
        guard !service.incarnations.isEmpty, service.incarnations.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.staleIdentity }
        var candidate = state
        if !service.activeClaims.contains(where: { $0.actor == request.actor }) {
            candidate.services[i].claims.append(ManagedClaim(id: UUID(), actor: request.actor, active: true, revision: service.revision + 1))
        }
        candidate.services[i].revision += 1; candidate.services[i].lifecycle = "running"
        for o in candidate.operations.indices where candidate.operations[o].serviceId == serviceId { candidate.operations[o].approved = false }
        let operation = UUID()
        candidate.operations.append(ManagedOperation(id: operation, serviceId: serviceId, action: "reuse", revision: candidate.services[i].revision,
                                                     targets: service.incarnations, generation: service.routeGeneration, actor: request.actor,
                                                     phase: "completed", outcome: "healthy_service_reused", expires: now()))
        let response = ManagedResponse(requestId: request.requestId, revision: candidate.services[i].revision, operationId: operation,
                                       data: try publicService(candidate.services[i]))
        candidate.replays[request.requestId] = ManagedReplay(actor: request.actor, digest: ManagedDigest.hash(try ManagedDigest.canonical(request)), response: response, date: now())
        candidate.revision += 1; try commit(candidate)
        releaseTimes.removeValue(forKey: serviceId)
        return response
    }

    public func adopt(_ request: ManagedRequest, workspace: ManagedWorkspace, name: String, variant: String,
                      target: ManagedIncarnation, port: UInt16) throws -> ManagedResponse {
        if let previous = preflight(request) {
            if let error = previous.error { throw error }
            return previous
        }
        guard actors.contains(where: { $0.id == request.actor && $0.scope == .user }) else { throw ManagedError.unauthorized }
        guard request.expectedRevision == 0 else { throw ManagedError.staleRevision }
        guard ManagedServiceName.isValid(name),
              ManagedServiceName.isValid(variant) else { throw ManagedError.invalidInput }
        guard let live = identity(target.pid) else { throw ManagedError.identityUnavailable }
        guard live == target else { throw ManagedError.staleIdentity }
        guard !state.services.contains(where: {
            ($0.workspace.filesystemIdentity == workspace.filesystemIdentity && $0.name == name && $0.variant == variant)
                || ($0.incarnations.contains(target) && $0.lifecycle != "stopped")
        }) else { throw ManagedError.incompatibleLaunch }
        var service = ManagedService(id: UUID(), workspace: workspace, name: name, variant: variant, launchFingerprint: "")
        if let existing = state.services.first(where: { $0.workspace.filesystemIdentity == workspace.filesystemIdentity }) { service.workspace = existing.workspace }
        service.lifecycle = "running"; service.incarnations = [target]; service.backendPort = port
        service.claims = [ManagedClaim(id: UUID(), actor: request.actor, active: true, revision: 1)]
        var candidate = state; candidate.services.append(service); candidate.revision += 1
        let response = ManagedResponse(requestId: request.requestId, revision: 1, data: try publicService(service))
        candidate.replays[request.requestId] = ManagedReplay(actor: request.actor, digest: ManagedDigest.hash(try ManagedDigest.canonical(request)), response: response, date: now())
        try commit(candidate)
        return response
    }

    public func snapshot() -> [ManagedService] { state.services }
    public func operation(id: UUID) -> ManagedOperation? { state.operations.first { $0.id == id } }
    public func enrollTailnet(_ request: ManagedRequest, route: ManagedTailnetRoute) throws -> ManagedResponse {
        if let previous = preflight(request) { return previous }
        guard actors.contains(where: { $0.id == request.actor && $0.scope == .user }) else { throw ManagedError.unauthorized }
        let i = try serviceIndex(request)
        try checkRevision(request, state.services[i])
        guard state.services[i].stablePort == route.stablePort, state.services[i].routeGeneration > 0,
              !state.services.contains(where: { $0.id != state.services[i].id && $0.tailnet?.selector == route.selector }) else { throw ManagedError.invalidInput }
        var candidate = state
        candidate.services[i].tailnet = route
        candidate.services[i].revision += 1
        for o in candidate.operations.indices where candidate.operations[o].serviceId == candidate.services[i].id { candidate.operations[o].approved = false }
        let response = ManagedResponse(requestId: request.requestId, revision: candidate.services[i].revision, data: try publicService(candidate.services[i]))
        candidate.replays[request.requestId] = ManagedReplay(actor: request.actor, digest: ManagedDigest.hash(try ManagedDigest.canonical(request)), response: response, date: now())
        candidate.revision += 1; try commit(candidate)
        return response
    }
    public func observeTailnet(serviceId: UUID, expectedFingerprint: String, observed: ManagedTailnetRoute?) throws {
        guard !recoveryRequired, state.maintenance == nil, let i = state.services.firstIndex(where: { $0.id == serviceId }),
              let enrolled = state.services[i].tailnet, enrolled.fingerprint == expectedFingerprint else { return }
        let verified = observed?.fingerprint == enrolled.fingerprint
        guard enrolled.verified != verified else { return }
        var candidate = state
        candidate.services[i].tailnet?.verified = verified
        candidate.services[i].tailnet?.observedAt = now()
        candidate.services[i].revision += 1
        candidate.revision += 1
        try commit(candidate)
    }
    public func handle(_ request: ManagedRequest, peer: ManagedIncarnation? = nil) -> ManagedResponse {
        // The global revision moves with activity on every service, so it is only ever shown to an
        // authenticated legacy caller. Any failure before that point (bad protocol version, unknown,
        // retired, replaced or faulted credential) reports 0.
        var authenticatedLegacy = false
        do {
            guard request.protocolVersion == 1 else { throw ManagedError.protocolMismatch }
            // Separate authority tables, no fallback: a legacy credential is tried first;
            // only when it does not match is the export sidecar consulted.
            let legacy = actors.first(where: { $0.id == request.actor &&
                ManagedDigest.hash(Data(request.credential.utf8)) == $0.credentialHash })
            let exportActor = legacy == nil ? authenticateExport(request) : nil
            guard legacy != nil || exportActor != nil else { throw ManagedError.unauthorized }
            authenticatedLegacy = legacy != nil
            if now() < lastWallTime {
                for i in state.operations.indices { state.operations[i].approved = false }
                approvalDeadlines.removeAll()
            }
            lastWallTime = now()
            if let exportActor {
                // Export actors never see the global registry revision, on success or on error.
                do { return try handleExport(request, actor: exportActor, peer: peer) }
                catch { return ManagedResponse(requestId: request.requestId, revision: 0, error: error as? ManagedError ?? .recoveryRequired) }
            }
            if ManagedExportOperation.isExport(request.operation) { return try handleExportAdmin(request, actor: legacy) }
            guard let actor = legacy else { throw ManagedError.unauthorized }
            guard !recoveryRequired else { throw ManagedError.recoveryRequired }
            let digest = ManagedDigest.hash(try ManagedDigest.canonical(request))
            if let previous = state.replays[request.requestId] {
                guard previous.actor == actor.id else { throw ManagedError.unauthorized }
                guard previous.digest == digest else { throw ManagedError.idempotencyConflict }
                return previous.response
            }
            if ["status", "services.list", "service.inspect", "events.list", "operations.list", "operation.inspect"].contains(request.operation) {
                return try read(request)
            }
            if ["lifecycle.quiesce", "lifecycle.resume"].contains(request.operation) {
                guard actor.scope == .user else { throw ManagedError.unauthorized }
                var candidate = state
                if request.operation == "lifecycle.quiesce" {
                    guard state.maintenance == nil, !state.services.contains(where: { $0.fence != nil }) else { throw ManagedError.operationInProgress }
                    // Active-child survival under launchd has not been accepted.
                    // A missing identity with a still-existing PID is uncertain.
                    guard state.services.flatMap(\.incarnations).allSatisfy(provenExited) else { throw ManagedError.needsDecision }
                    candidate.maintenance = request.requestId
                } else {
                    guard let checkpoint = request.payload["checkpoint"]?.string,
                          checkpoint == state.maintenance else { throw ManagedError.staleRevision }
                    candidate.maintenance = nil
                }
                candidate.revision += 1
                let response = ManagedResponse(requestId: request.requestId, revision: candidate.revision,
                    data: .object(["checkpoint": candidate.maintenance.map(ManagedJSON.string) ?? .null]))
                candidate.replays[request.requestId] = ManagedReplay(actor: actor.id, digest: digest, response: response, date: now())
                try commit(candidate)
                return response
            }
            guard state.maintenance == nil else { throw ManagedError.operationInProgress }
            guard actor.scope != .read else { throw ManagedError.unauthorized }
            if request.operation == "operation.execute" { return try execute(request, actor: actor, digest: digest) }
            let original = state
            let originalTimers = releaseTimes
            let originalApprovals = approvalDeadlines
            do {
                let response = try mutate(request, actor: actor)
                state.replays[request.requestId] = ManagedReplay(actor: actor.id, digest: digest, response: response, date: now())
                // Request history is bounded by retention; active records are never evicted.
                state.replays = state.replays.filter { now().timeIntervalSince($0.value.date) <= 7 * 86400 }
                state.revision += 1
                let candidate = state
                state = original
                try commit(candidate)
                return response
            } catch {
                state = original; releaseTimes = originalTimers; approvalDeadlines = originalApprovals
                if !(error is ManagedError) || error as? ManagedError == .recoveryRequired { recoveryRequired = true }
                throw error
            }
        } catch {
            return ManagedResponse(requestId: request.requestId, revision: authenticatedLegacy ? state.revision : 0,
                                   error: error as? ManagedError ?? .recoveryRequired)
        }
    }
    private func uuid(_ request: ManagedRequest, _ key: String) throws -> UUID {
        guard let value = request.payload[key]?.string, let id = UUID(uuidString: value) else { throw ManagedError.invalidInput }; return id
    }
    private func serviceIndex(_ request: ManagedRequest) throws -> Int {
        let id = try uuid(request, "serviceId")
        guard let i = state.services.firstIndex(where: { $0.id == id }) else { throw ManagedError.needsDecision }
        return i
    }
    private func checkRevision(_ request: ManagedRequest, _ service: ManagedService) throws {
        if service.fence != nil {
            let forceProposal = request.operation == "operation.propose" && request.payload["action"]?.string == "force"
            let operationId = request.payload["operationId"]?.string.flatMap(UUID.init(uuidString:))
            let forceDecision = ["decision.resolve", "operation.execute"].contains(request.operation) &&
                state.operations.contains { $0.id == operationId && $0.serviceId == service.id && $0.action == "force" }
            guard (forceProposal || forceDecision), service.lifecycle == "stopping",
                  let sentAt = signalTimes[service.id], uptime() - sentAt >= 2 else { throw ManagedError.operationInProgress }
        }
        guard request.expectedRevision == service.revision else { throw ManagedError.staleRevision }
    }
    private func read(_ request: ManagedRequest) throws -> ManagedResponse {
        var data: ManagedJSON
        var revision = state.revision
        switch request.operation {
        case "status": data = .object(["schema": .integer(1), "protocolVersion": .integer(1), "mutationsEnabled": .bool(!recoveryRequired && state.maintenance == nil), "actor": .string(request.actor), "checkpoint": state.maintenance.map(ManagedJSON.string) ?? .null])
        case "service.inspect":
            let service = state.services[try serviceIndex(request)]; revision = service.revision
            data = try publicService(service)
        case "events.list":
            if let value = request.payload["limit"], value.integer == nil { throw ManagedError.invalidInput }
            let limit = min(request.payload["limit"]?.integer ?? 50, 200)
            guard limit > 0 else { throw ManagedError.invalidInput }
            var after = (state.events.first?.sequence ?? (state.lastEventSequence + 1)) - 1
            if let cursor = request.payload["cursor"] {
                guard let string = cursor.string, let bytes = Data(base64Encoded: string),
                      let raw = String(data: bytes, encoding: .utf8), raw.hasPrefix("events:"),
                      let sequence = Int(raw.dropFirst(7)), sequence >= 0, sequence <= state.lastEventSequence else { throw ManagedError.invalidInput }
                after = sequence
                let firstRetained = state.events.first?.sequence ?? state.lastEventSequence + 1
                guard after >= firstRetained - 1 else { throw ManagedError.resyncRequired }
            }
            let page = Array(state.events.filter { $0.sequence > after }.prefix(limit))
            let consumed = page.last?.sequence ?? after
            let cursor = Data("events:\(consumed)".utf8).base64EncodedString()
            data = .object(["records": .array(try page.map { try .value($0) }), "cursor": .string(cursor),
                            "hasMore": .bool(consumed < state.lastEventSequence)])
        case "operation.inspect":
            let id = try uuid(request, "operationId")
            guard let operation = state.operations.first(where: { $0.id == id }) else { throw ManagedError.invalidInput }
            data = try .value(operation)
        default:
            if let value = request.payload["limit"], value.integer == nil { throw ManagedError.invalidInput }
            if let value = request.payload["cursor"], value.string == nil { throw ManagedError.invalidInput }
            let requested = request.payload["limit"]?.integer ?? 50
            guard requested > 0 else { throw ManagedError.invalidInput }
            let limit = min(requested, 200)
            let offset: Int
            if let cursor = request.payload["cursor"]?.string {
                guard let bytes = Data(base64Encoded: cursor), let token = String(data: bytes, encoding: .utf8) else { throw ManagedError.invalidInput }
                let parts = token.split(separator: ":")
                guard parts.count == 3, parts[0] == request.operation,
                      Int(parts[1]) == state.revision, let parsed = Int(parts[2]), parsed >= 0 else { throw ManagedError.staleRevision }
                offset = parsed
            } else { offset = 0 }
            let records = try request.operation == "operations.list" ? state.operations.map { try ManagedJSON.value($0) } : state.services.map(publicService)
            guard offset <= records.count else { throw ManagedError.invalidInput }
            var page: [ManagedJSON] = []; var size = 0
            for record in records.dropFirst(offset).prefix(limit) {
                let bytes = try JSONEncoder().encode(record).count
                guard bytes < ManagedWire.responseLimit - 4096 else { throw ManagedError.recordTooLarge }
                if size + bytes > ManagedWire.responseLimit - 4096 { break }
                page.append(record); size += bytes
            }
            let end = offset + page.count
            let cursor: ManagedJSON = end < records.count ? .string(Data("\(request.operation):\(state.revision):\(end)".utf8).base64EncodedString()) : .null
            data = .object(["records": .array(page), "cursor": cursor])
        }
        return ManagedResponse(requestId: request.requestId, revision: revision, data: data)
    }
    private func publicService(_ service: ManagedService) throws -> ManagedJSON {
        var value = try ManagedJSON.value(service)
        if case .object(var fields) = value {
            fields.removeValue(forKey: "launchFingerprint")
            if let proxy = ManagedProcess.incarnation(pid: getpid()) { fields["proxyIncarnation"] = try .value(proxy) }
            value = .object(fields)
        }
        return value
    }
    /// The single exit rule: a different identity at the PID (reuse) or an OS-confirmed ESRCH.
    /// A missing identity alone is never proof of exit.
    func provenExited(_ target: ManagedIncarnation) -> Bool {
        if let live = identity(target.pid) { return live != target }
        return isGone(target.pid)
    }
    /// A recorded descendant may be pruned or skipped once proven exited, but only for a service with
    /// no route transition: a reroute leaves a second root (the new backend) at a later index, so
    /// position no longer identifies roots. While a transition exists every mismatch fails closed.
    private func canPrune(_ service: ManagedService, at index: Int) -> Bool {
        index > 0 && service.transition == nil
    }
    /// Every recorded target must be live and matching (strict), or, when `tolerant`, a prunable
    /// descendant that is proven exited is skipped. Any other mismatch fails closed.
    /// Returns the targets that are live now.
    /// `skipAnyExited` (stop/force only) skips a proven-exited target at any position, root included: skipping
    /// never signals anything, and after a failed move the record can hold a dead root that must not make the
    /// live old backend unstoppable. It never prunes the record.
    @discardableResult
    private func requireLiveIncarnations(_ service: ManagedService, tolerant: Bool = true, skipAnyExited: Bool = false) throws -> [ManagedIncarnation] {
        guard !service.incarnations.isEmpty else { throw ManagedError.identityUnavailable }
        var live: [ManagedIncarnation] = []
        for (n, target) in service.incarnations.enumerated() {
            if let current = identity(target.pid), current == target { live.append(target); continue }
            if (skipAnyExited || (tolerant && canPrune(service, at: n))) && provenExited(target) { continue }
            guard identity(target.pid) != nil else { throw ManagedError.identityUnavailable }
            throw ManagedError.staleIdentity
        }
        return live
    }
    private func mutate(_ request: ManagedRequest, actor: ManagedActor) throws -> ManagedResponse {
        let i = try serviceIndex(request)
        try checkRevision(request, state.services[i])
        switch request.operation {
        case "claim.acquire":
            guard actor.scope == .owner || actor.scope == .user else { throw ManagedError.unauthorized }
            guard ["running", "release_pending"].contains(state.services[i].lifecycle) else { throw ManagedError.needsDecision }
            try requireLiveIncarnations(state.services[i])
            if !state.services[i].activeClaims.contains(where: { $0.actor == actor.id }) {
                state.services[i].claims.append(ManagedClaim(id: UUID(), actor: actor.id, active: true, revision: state.services[i].revision + 1))
            }
            state.services[i].lifecycle = "running"; releaseTimes.removeValue(forKey: state.services[i].id)
        case "claim.release":
            let claimId = try uuid(request, "claimId")
            guard let c = state.services[i].claims.firstIndex(where: { $0.id == claimId }),
                  state.services[i].claims[c].actor == actor.id else { throw ManagedError.unauthorized }
            state.services[i].claims[c].active = false
            state.services[i].claims[c].revision = state.services[i].revision + 1
            if state.services[i].activeClaims.isEmpty && !state.services[i].keepRunning && ["running", "release_pending"].contains(state.services[i].lifecycle) {
                state.services[i].lifecycle = "release_pending"; releaseTimes[state.services[i].id] = uptime()
            }
        case "service.keep":
            guard actor.scope == .user else { throw ManagedError.unauthorized }
            guard ["running", "release_pending"].contains(state.services[i].lifecycle) else { throw ManagedError.needsDecision }
            guard let keep = request.payload["keep"]?.bool else { throw ManagedError.invalidInput }
            try requireLiveIncarnations(state.services[i])
            state.services[i].keepRunning = keep
            releaseTimes.removeValue(forKey: state.services[i].id)
            if !keep && state.services[i].activeClaims.isEmpty {
                state.services[i].lifecycle = "release_pending"; releaseTimes[state.services[i].id] = uptime()
            } else if state.services[i].lifecycle == "release_pending" { state.services[i].lifecycle = "running" }
        case "operation.propose":
            guard let action = request.payload["action"]?.string, ["stop", "reroute", "force"].contains(action) else { throw ManagedError.invalidInput }
            guard actor.scope == .user || actor.scope == .coordinator || state.services[i].activeClaims.contains(where: { $0.actor == actor.id }) else { throw ManagedError.unauthorized }
            let s = state.services[i]
            if action == "force" {
                guard s.lifecycle == "stopping", let sentAt = signalTimes[s.id], uptime() - sentAt >= 2 else { throw ManagedError.needsDecision }
            }
            let operation = ManagedOperation(id: UUID(), serviceId: s.id, action: action, revision: s.revision,
                                             targets: s.incarnations, generation: s.routeGeneration, actor: actor.id,
                                             phase: "proposed", expires: now().addingTimeInterval(600))
            state.operations.append(operation)
            approvalDeadlines[operation.id] = uptime() + 600
            event("operation.proposed", service: s, operation: operation.id)
            return ManagedResponse(requestId: request.requestId, status: "pending", revision: s.revision, operationId: operation.id)
        case "operation.acknowledge", "decision.resolve":
            let id = try uuid(request, "operationId")
            guard let o = state.operations.firstIndex(where: { $0.id == id }),
                  state.operations[o].serviceId == state.services[i].id,
                  state.operations[o].revision == state.services[i].revision,
                  state.operations[o].targets == state.services[i].incarnations,
                  state.operations[o].generation == state.services[i].routeGeneration,
                  state.operations[o].expires > now(),
                  (approvalDeadlines[id] ?? 0) > uptime(), state.operations[o].phase == "proposed" else { throw ManagedError.staleRevision }
            if request.operation == "decision.resolve" {
                guard actor.scope == .user, let approved = request.payload["approved"]?.bool else { throw ManagedError.unauthorized }
                state.operations[o].approved = approved
                state.operations[o].phase = approved ? "authorized" : "denied"
            } else {
                guard state.services[i].activeClaims.contains(where: { $0.actor == actor.id }) else { throw ManagedError.unauthorized }
                if !state.operations[o].acknowledgements.contains(actor.id) { state.operations[o].acknowledgements.append(actor.id) }
            }
            return ManagedResponse(requestId: request.requestId, status: "pending", revision: state.services[i].revision, operationId: id)
        default: throw ManagedError.dependencyUnavailable
        }
        state.services[i].revision += 1
        // Any ownership change invalidates every earlier destructive proposal.
        for o in state.operations.indices where state.operations[o].serviceId == state.services[i].id {
            state.operations[o].approved = false
        }
        event(request.operation, service: state.services[i])
        return ManagedResponse(requestId: request.requestId, revision: state.services[i].revision, data: try publicService(state.services[i]))
    }
    private func event(_ kind: String, service: ManagedService, operation: UUID? = nil) {
        state.lastEventSequence += 1
        state.events.append(ManagedEvent(sequence: state.lastEventSequence, serviceId: service.id,
                                        operationId: operation, kind: kind, revision: service.revision, date: now()))
    }

    /// Commit a start intent before the supervisor creates a child. Identity is
    /// supplied only by the trusted local supervisor, never by a wire payload.
    public func beginLaunch(_ request: ManagedRequest, workspace: ManagedWorkspace, name: String,
                            variant: String, fingerprint: String, backend: UInt16, stable: UInt16) throws -> ManagedService {
        guard !recoveryRequired else { throw ManagedError.recoveryRequired }
        guard state.maintenance == nil else { throw ManagedError.operationInProgress }
        guard let actor = actors.first(where: { $0.id == request.actor }),
              actor.scope == .owner || actor.scope == .user,
              actor.credentialHash == ManagedDigest.hash(Data(request.credential.utf8)) else { throw ManagedError.unauthorized }
        guard request.protocolVersion == 1 else { throw ManagedError.protocolMismatch }
        guard request.expectedRevision == 0 else { throw ManagedError.staleRevision }
        guard ManagedServiceName.isValid(name),
              ManagedServiceName.isValid(variant) else { throw ManagedError.invalidInput }
        if state.services.contains(where: { $0.workspace.filesystemIdentity == workspace.filesystemIdentity && $0.name == name && $0.variant == variant }) {
            // Reuse needs a fresh health probe and configuration comparison. Until
            // then fail closed instead of making a claim on uncertain liveness.
            throw ManagedError.incompatibleLaunch
        }
        let digest = ManagedDigest.hash(try ManagedDigest.canonical(request))
        if let old = state.replays[request.requestId] {
            guard old.actor == actor.id else { throw ManagedError.unauthorized }
            guard old.digest == digest else { throw ManagedError.idempotencyConflict }
            throw ManagedError.operationInProgress
        }
        var service = ManagedService(id: UUID(), workspace: workspace, name: name, variant: variant, launchFingerprint: fingerprint)
        if let existing = state.services.first(where: { $0.workspace.filesystemIdentity == workspace.filesystemIdentity }) {
            service.workspace = existing.workspace
        }
        guard !state.services.contains(where: { $0.stablePort == stable || ($0.backendPort == backend && $0.lifecycle != "stopped") }) else { throw ManagedError.portUnavailable }
        service.claims = [ManagedClaim(id: UUID(), actor: actor.id, active: true, revision: 1)]
        service.backendPort = backend; service.stablePort = stable
        let operationId = UUID()
        service.fence = operationId
        var candidate = state
        candidate.services.append(service)
        candidate.operations.append(ManagedOperation(id: operationId, serviceId: service.id, action: "run", revision: 1,
                                                     targets: [], generation: 0, actor: actor.id, phase: "starting", expires: now().addingTimeInterval(30)))
        let response = ManagedResponse(requestId: request.requestId, status: "accepted", revision: 1,
                                       operationId: operationId, data: .object(["serviceId": .string(service.id.uuidString)]))
        candidate.replays[request.requestId] = ManagedReplay(actor: actor.id, digest: digest, response: response, date: now())
        candidate.revision += 1
        try commit(candidate)
        return service
    }
    public func recordChild(serviceId: UUID, incarnation: ManagedIncarnation) throws {
        guard let i = state.services.firstIndex(where: { $0.id == serviceId }), state.services[i].lifecycle == "starting" else { throw ManagedError.staleRevision }
        var candidate = state; candidate.services[i].incarnations.append(incarnation); candidate.revision += 1
        try commit(candidate)
    }
    public func restartLaunch(_ request: ManagedRequest, serviceId: UUID, fingerprint: String, backend: UInt16) throws -> ManagedService {
        guard preflight(request) == nil,
              actors.contains(where: { $0.id == request.actor && ($0.scope == .owner || $0.scope == .user) }),
              let i = state.services.firstIndex(where: { $0.id == serviceId }) else { throw ManagedError.unauthorized }
        let service = state.services[i]
        try checkRevision(request, service)
        // A needs_review service is restartable only once every process it ever recorded is proven gone.
        // An empty record counts as finished: a launch records its child before resuming it, so a launch
        // that recorded nothing (spawn failed, or the helper died first) never ran any user code.
        let finished = service.lifecycle == "stopped" ? service.transition == nil
            : service.lifecycle == "needs_review" && service.fence == nil
                && (service.incarnations + (service.transition.map { $0.oldTargets + $0.newTargets } ?? [])).allSatisfy(provenExited)
        guard finished, service.launchFingerprint == fingerprint,
              !state.services.contains(where: { $0.lifecycle != "stopped" && ($0.backendPort == backend || $0.transition?.newBackend == backend) }) else { throw ManagedError.incompatibleLaunch }
        var candidate = state
        let id = UUID()
        candidate.services[i].lifecycle = "starting"
        candidate.services[i].incarnations = []; candidate.services[i].treeComplete = false
        candidate.services[i].transition = nil
        candidate.services[i].backendPort = backend; candidate.services[i].fence = id
        candidate.services[i].revision += 1
        if !service.activeClaims.contains(where: { $0.actor == request.actor }) {
            candidate.services[i].claims.append(ManagedClaim(id: UUID(), actor: request.actor, active: true, revision: candidate.services[i].revision))
        }
        candidate.operations.append(ManagedOperation(id: id, serviceId: serviceId, action: "run", revision: candidate.services[i].revision,
            targets: [], generation: service.routeGeneration, actor: request.actor, phase: "starting", expires: now().addingTimeInterval(30)))
        let response = ManagedResponse(requestId: request.requestId, status: "accepted", revision: candidate.services[i].revision, operationId: id,
                                       data: .object(["serviceId": .string(serviceId.uuidString)]))
        candidate.replays[request.requestId] = ManagedReplay(actor: request.actor, digest: ManagedDigest.hash(try ManagedDigest.canonical(request)), response: response, date: now())
        candidate.revision += 1; try commit(candidate)
        return candidate.services[i]
    }
    public func recordDescendants(serviceId: UUID, expectedRevision: Int, descendants: [ManagedIncarnation]) throws {
        guard !recoveryRequired else { throw ManagedError.recoveryRequired }
        guard let i = state.services.firstIndex(where: { $0.id == serviceId }),
              state.services[i].revision == expectedRevision,
              ["starting", "running", "release_pending"].contains(state.services[i].lifecycle) else { throw ManagedError.staleRevision }
        guard state.services[i].lifecycle == "starting" || state.services[i].fence == nil else { throw ManagedError.operationInProgress }
        let additions = descendants.filter { !state.services[i].incarnations.contains($0) }
        guard !additions.isEmpty else { return }
        guard additions.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.staleIdentity }
        var candidate = state
        candidate.services[i].incarnations += additions
        candidate.services[i].treeComplete = false
        candidate.services[i].revision += 1
        for o in candidate.operations.indices where candidate.operations[o].serviceId == serviceId {
            candidate.operations[o].approved = false
        }
        candidate.revision += 1
        try commit(candidate)
    }
    public func finishLaunch(serviceId: UUID, ready: Bool, treeComplete: Bool) throws {
        guard let i = state.services.firstIndex(where: { $0.id == serviceId }), state.services[i].lifecycle == "starting" else { throw ManagedError.staleRevision }
        var candidate = state
        candidate.services[i].lifecycle = ready ? "running" : "needs_review"
        candidate.services[i].treeComplete = treeComplete
        if ready { candidate.services[i].routeGeneration += 1 }
        if let o = candidate.operations.firstIndex(where: { $0.id == candidate.services[i].fence }) {
            candidate.operations[o].phase = ready ? "completed" : "needs_review"
            candidate.operations[o].outcome = ready ? "listener_verified" : "readiness_failed"
        }
        candidate.services[i].fence = nil; candidate.services[i].revision += 1; candidate.revision += 1
        try commit(candidate)
    }
    public func beginReroute(_ request: ManagedRequest, backend: UInt16) throws -> ManagedResponse {
        if let previous = preflight(request) { return previous }
        guard actors.contains(where: { $0.id == request.actor && ($0.scope == .user || $0.scope == .coordinator) }) else { throw ManagedError.unauthorized }
        let i = try serviceIndex(request), id = try uuid(request, "operationId")
        let service = state.services[i]
        try checkRevision(request, service)
        guard service.lifecycle == "running", service.transition == nil, let old = service.backendPort,
              service.stablePort != nil, old != backend,
              !state.services.contains(where: { $0.backendPort == backend || $0.transition?.newBackend == backend }),
              let o = state.operations.firstIndex(where: { $0.id == id }) else { throw ManagedError.needsDecision }
        let operation = state.operations[o]
        guard operation.action == "reroute", operation.serviceId == service.id, operation.revision == service.revision,
              operation.targets == service.incarnations, operation.generation == service.routeGeneration,
              ["proposed", "authorized"].contains(operation.phase), operation.expires > now(),
              (approvalDeadlines[id] ?? 0) > uptime() else { throw ManagedError.staleRevision }
        guard operation.approved || (!service.activeClaims.isEmpty && service.activeClaims.allSatisfy({ operation.acknowledgements.contains($0.actor) })) else { throw ManagedError.needsDecision }
        try requireLiveIncarnations(service, tolerant: false)
        var candidate = state
        candidate.services[i].transition = ManagedRouteTransition(operationId: id, oldBackend: old, newBackend: backend,
            oldGeneration: service.routeGeneration, oldTargets: service.incarnations, newTargets: [], phase: "preparing")
        candidate.operations[o].phase = "preparing"
        let response = ManagedResponse(requestId: request.requestId, status: "accepted", revision: service.revision, operationId: id)
        candidate.replays[request.requestId] = ManagedReplay(actor: request.actor, digest: ManagedDigest.hash(try ManagedDigest.canonical(request)), response: response, date: now())
        candidate.revision += 1; try commit(candidate)
        return response
    }
    public func recordReplacement(serviceId: UUID, operationId: UUID, targets: [ManagedIncarnation]) throws {
        guard !recoveryRequired, state.maintenance == nil,
              let i = state.services.firstIndex(where: { $0.id == serviceId }),
              state.services[i].transition?.operationId == operationId,
              state.services[i].transition?.phase == "preparing",
              !targets.isEmpty, Set(targets.map(\.pid)).count == targets.count,
              targets.allSatisfy({ new in !state.services[i].incarnations.contains(where: { $0.pid == new.pid }) }),
              targets.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.staleIdentity }
        var candidate = state
        candidate.services[i].transition?.newTargets = targets
        candidate.revision += 1; try commit(candidate)
    }
    /// The pointer switch is synchronous and inside the same actor turn as the
    /// final revision/identity checks and durable fence. There is no await gap.
    public func switchReroute(serviceId: UUID, operationId: UUID,
                              switchRoute: @Sendable (UInt16, Int) -> Void) throws {
        guard !recoveryRequired, state.maintenance == nil,
              let i = state.services.firstIndex(where: { $0.id == serviceId }),
              let o = state.operations.firstIndex(where: { $0.id == operationId }),
              let transition = state.services[i].transition, transition.operationId == operationId,
              transition.phase == "preparing" else { throw ManagedError.staleRevision }
        let service = state.services[i], operation = state.operations[o]
        guard service.fence == nil, service.revision == operation.revision,
              service.incarnations == operation.targets, service.routeGeneration == operation.generation,
              now() >= lastWallTime, operation.expires > now(), (approvalDeadlines[operationId] ?? 0) > uptime() else { throw ManagedError.staleRevision }
        guard operation.approved || (!service.activeClaims.isEmpty && service.activeClaims.allSatisfy({ operation.acknowledgements.contains($0.actor) })) else { throw ManagedError.needsDecision }
        let targets = transition.oldTargets + transition.newTargets
        guard !transition.newTargets.isEmpty, targets.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.staleIdentity }
        var candidate = state
        candidate.services[i].fence = operationId
        candidate.services[i].transition?.phase = "ready"
        candidate.operations[o].phase = "fenced"; candidate.operations[o].approved = false
        let priorOperationPhase = state.operations[o].phase, priorApproved = state.operations[o].approved
        candidate.revision += 1; try commit(candidate)
        guard targets.allSatisfy({ identity($0.pid) == $0 }) else {
            // Nothing was switched yet: undo exactly what the first commit changed so the
            // transition is "preparing" again and abandonReplacement can still apply.
            var revert = state
            revert.services[i].fence = nil
            revert.services[i].transition?.phase = "preparing"
            revert.operations[o].phase = priorOperationPhase; revert.operations[o].approved = priorApproved
            revert.revision += 1
            try? commit(revert)
            throw ManagedError.staleIdentity
        }
        switchRoute(transition.newBackend, transition.oldGeneration + 1)
        candidate = state
        candidate.services[i].backendPort = transition.newBackend
        candidate.services[i].routeGeneration = transition.oldGeneration + 1
        candidate.services[i].incarnations = targets
        candidate.services[i].treeComplete = false
        candidate.services[i].transition?.phase = "switched"
        candidate.services[i].revision += 1
        candidate.operations[o].phase = "observing"
        candidate.revision += 1; try commit(candidate)
    }
    public func finishReroute(serviceId: UUID, operationId: UUID, outcome: String) throws {
        guard !recoveryRequired,
              let i = state.services.firstIndex(where: { $0.id == serviceId }),
              let transition = state.services[i].transition, transition.operationId == operationId,
              let o = state.operations.firstIndex(where: { $0.id == operationId }) else { throw ManagedError.staleRevision }
        guard state.services[i].fence == nil || state.services[i].fence == operationId else { throw ManagedError.operationInProgress }
        var candidate = state
        // Retain every known process, including an unready replacement. A failed
        // preparation never discards identities or silently kills descendants.
        for target in transition.newTargets where !candidate.services[i].incarnations.contains(target) {
            candidate.services[i].incarnations.append(target)
        }
        candidate.services[i].fence = nil
        candidate.services[i].transition?.phase = "needs_review"
        if outcome == "no_healthy_backend" { candidate.services[i].lifecycle = "degraded" }
        else if transition.phase == "ready" { candidate.services[i].lifecycle = "needs_review" }
        candidate.services[i].revision += 1
        candidate.operations[o].phase = "needs_review"; candidate.operations[o].outcome = outcome
        candidate.operations[o].approved = false
        candidate.revision += 1; try commit(candidate)
    }
    /// A failed preparation whose replacement was proven exited: drop the transition and keep only the old
    /// backend's incarnations. Never merges the dead replacement into `incarnations`, so the still-serving
    /// old backend stays running and stoppable. Refuses while any replacement target is not proven exited.
    public func abandonReplacement(serviceId: UUID, operationId: UUID, outcome: String) throws {
        guard !recoveryRequired,
              let i = state.services.firstIndex(where: { $0.id == serviceId }),
              let transition = state.services[i].transition, transition.operationId == operationId,
              transition.phase == "preparing",
              let o = state.operations.firstIndex(where: { $0.id == operationId }) else { throw ManagedError.staleRevision }
        guard state.services[i].fence == nil || state.services[i].fence == operationId else { throw ManagedError.operationInProgress }
        guard transition.newTargets.allSatisfy(provenExited) else { throw ManagedError.needsDecision }
        var candidate = state
        candidate.services[i].transition = nil
        candidate.services[i].fence = nil
        candidate.services[i].revision += 1
        candidate.operations[o].phase = "needs_review"; candidate.operations[o].outcome = outcome
        candidate.operations[o].approved = false
        candidate.revision += 1; try commit(candidate)
    }
    public func retireOldRoute(serviceId: UUID, operationId: UUID, treeVerified: @Sendable () -> Bool) throws {
        guard !recoveryRequired, let i = state.services.firstIndex(where: { $0.id == serviceId }),
              state.services[i].fence == operationId, let transition = state.services[i].transition,
              transition.operationId == operationId, transition.phase == "switched",
              let o = state.operations.firstIndex(where: { $0.id == operationId }), treeVerified(),
              transition.oldTargets.allSatisfy({ identity($0.pid) == $0 }),
              transition.newTargets.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.needsDecision }
        var candidate = state
        candidate.services[i].transition?.phase = "retiring_old"
        candidate.operations[o].phase = "retiring_old"
        candidate.revision += 1; try commit(candidate)
        guard treeVerified() else { throw ManagedError.needsDecision }
        for target in transition.oldTargets {
            guard identity(target.pid) == target, sendSignal(target, false) else { throw ManagedError.staleIdentity }
        }
    }
    public func completeReroute(serviceId: UUID, operationId: UUID, oldTreeVerified: Bool, newTreeVerified: Bool) throws {
        guard !recoveryRequired, oldTreeVerified,
              let i = state.services.firstIndex(where: { $0.id == serviceId }), state.services[i].fence == operationId,
              let transition = state.services[i].transition, transition.operationId == operationId,
              transition.phase == "retiring_old", let o = state.operations.firstIndex(where: { $0.id == operationId }),
              transition.newTargets.allSatisfy({ identity($0.pid) == $0 }),
              transition.oldTargets.allSatisfy(provenExited) else { throw ManagedError.needsDecision }
        var candidate = state
        candidate.services[i].incarnations = transition.newTargets
        candidate.services[i].treeComplete = newTreeVerified
        candidate.services[i].transition = nil; candidate.services[i].fence = nil
        candidate.services[i].lifecycle = "running"; candidate.services[i].revision += 1
        candidate.operations[o].phase = "completed"
        candidate.operations[o].outcome = "route_verified_old_exit_verified"
        candidate.revision += 1; try commit(candidate)
    }
    public func rollbackReroute(serviceId: UUID, operationId: UUID,
                                switchRoute: @Sendable (UInt16, Int) -> Void) throws {
        guard !recoveryRequired, let i = state.services.firstIndex(where: { $0.id == serviceId }),
              state.services[i].fence == operationId,
              let transition = state.services[i].transition, transition.operationId == operationId,
              transition.phase == "switched",
              transition.oldTargets.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.staleIdentity }
        var candidate = state
        candidate.services[i].transition?.phase = "rolling_back"
        candidate.revision += 1; try commit(candidate)
        guard transition.oldTargets.allSatisfy({ identity($0.pid) == $0 }) else { throw ManagedError.staleIdentity }
        let generation = state.services[i].routeGeneration + 1
        switchRoute(transition.oldBackend, generation)
        candidate = state
        candidate.services[i].backendPort = transition.oldBackend
        candidate.services[i].routeGeneration = generation
        candidate.revision += 1; try commit(candidate)
        try finishReroute(serviceId: serviceId, operationId: operationId, outcome: "rolled_back_replacement_retained_for_review")
    }
    private func execute(_ request: ManagedRequest, actor: ManagedActor, digest: String) throws -> ManagedResponse {
        let i = try serviceIndex(request)
        try checkRevision(request, state.services[i])
        let id = try uuid(request, "operationId")
        guard let o = state.operations.firstIndex(where: { $0.id == id }) else { throw ManagedError.invalidInput }
        let operation = state.operations[o]; let service = state.services[i]
        guard actor.scope == .user || actor.scope == .coordinator else { throw ManagedError.unauthorized }
        guard operation.serviceId == service.id, operation.revision == service.revision,
              operation.targets == service.incarnations, operation.generation == service.routeGeneration,
              operation.expires > now(), (approvalDeadlines[id] ?? 0) > uptime(),
              ["proposed", "authorized"].contains(operation.phase) else { throw ManagedError.staleRevision }
        guard operation.action != "reroute" else { throw ManagedError.dependencyUnavailable }
        // Forced termination ALWAYS needs a separately approved force operation.
        guard operation.approved else { throw ManagedError.needsDecision }
        guard !operation.targets.isEmpty else { throw ManagedError.identityUnavailable }
        // Proven-exited targets are skipped; anything uncertain still fails closed.
        let liveTargets = try requireLiveIncarnations(service, skipAnyExited: true)
        // Nothing left to signal means the recorded set changed under this approval; reconcile decides.
        guard !liveTargets.isEmpty else { throw ManagedError.staleIdentity }
        var candidate = state
        candidate.services[i].fence = id; candidate.services[i].lifecycle = "stopping"
        candidate.operations[o].phase = "fenced"; candidate.operations[o].approved = false
        let response = ManagedResponse(requestId: request.requestId, status: "accepted", revision: service.revision, operationId: id)
        candidate.replays[request.requestId] = ManagedReplay(actor: actor.id, digest: digest, response: response, date: now())
        candidate.revision += 1
        try commit(candidate)
        // No suspension from the final check through each checked signal.
        var sent = true
        for target in liveTargets {
            guard identity(target.pid) == target, sendSignal(target, operation.action == "force") else { sent = false; break }
        }
        candidate = state
        if sent { signalTimes[service.id] = uptime() }
        candidate.operations[o].phase = sent ? "signal_sent" : "needs_review"
        candidate.operations[o].outcome = sent ? "exit_not_yet_verified" : "identity_or_signal_failed"
        // A failed signal ends this operation; nothing would ever release its fence. Restart still
        // requires every recorded process proven exited, so releasing it cannot hide a live one.
        if !sent { candidate.services[i].lifecycle = "needs_review"; candidate.services[i].fence = nil }
        candidate.revision += 1; try commit(candidate)
        return response
    }

    public func reconcileStops(treeVerified: @Sendable (UUID) -> Bool = { _ in true }) throws {
        guard !recoveryRequired else { throw ManagedError.recoveryRequired }
        guard state.maintenance == nil else { return }
        for i in state.services.indices where ["running", "release_pending"].contains(state.services[i].lifecycle) && state.services[i].fence == nil {
            let lostProof = state.services[i].treeComplete && !treeVerified(state.services[i].id)
            // An exited descendant is pruned and the service stays running. The root exiting, or any
            // recorded process neither live nor proven exited, needs review.
            var kept: [ManagedIncarnation] = []; var needsReview = lostProof
            for (n, target) in state.services[i].incarnations.enumerated() {
                if identity(target.pid) == target { kept.append(target) }
                else if !canPrune(state.services[i], at: n) || !provenExited(target) { needsReview = true }
            }
            guard needsReview || kept.count != state.services[i].incarnations.count else { continue }
            var candidate = state
            if needsReview {
                candidate.services[i].lifecycle = "needs_review"
                if lostProof { candidate.services[i].treeComplete = false }
                releaseTimes.removeValue(forKey: candidate.services[i].id)
            } else {
                candidate.services[i].incarnations = kept
                for o in candidate.operations.indices where candidate.operations[o].serviceId == candidate.services[i].id {
                    candidate.operations[o].approved = false
                }
            }
            candidate.services[i].revision += 1; candidate.revision += 1
            try commit(candidate)
        }
        for i in state.services.indices where state.services[i].lifecycle == "stopping" {
            guard let id = state.services[i].fence,
                  let o = state.operations.firstIndex(where: { $0.id == id }) else { continue }
            // nil identity alone is never evidence of exit. ESRCH is required.
            guard state.services[i].incarnations.allSatisfy(provenExited) else { continue }
            var candidate = state
            candidate.services[i].treeComplete = candidate.services[i].treeComplete && treeVerified(candidate.services[i].id)
            candidate.services[i].fence = nil
            candidate.services[i].lifecycle = candidate.services[i].treeComplete ? "stopped" : "needs_review"
            candidate.services[i].revision += 1
            candidate.operations[o].phase = candidate.services[i].treeComplete ? "completed" : "needs_review"
            candidate.operations[o].outcome = candidate.services[i].treeComplete ? "exit_verified" : "known_processes_exited_tree_unverified"
            candidate.revision += 1; try commit(candidate)
        }
    }

    private func commit(_ candidate: ManagedState) throws {
        var candidate = candidate
        // Transitions outside request dispatch (startup, recovery, signals) also
        // emit durable events. No argv, environment or launch digest is reported.
        if candidate.lastEventSequence == state.lastEventSequence {
            for service in candidate.services {
                let prior = state.services.first { $0.id == service.id }
                if prior?.revision != service.revision || prior?.lifecycle != service.lifecycle || prior?.fence != service.fence {
                    candidate.lastEventSequence += 1
                    candidate.events.append(ManagedEvent(sequence: candidate.lastEventSequence, serviceId: service.id,
                                                        operationId: service.fence, kind: "service." + service.lifecycle,
                                                        revision: service.revision, date: now()))
                }
            }
            for operation in candidate.operations {
                let prior = state.operations.first { $0.id == operation.id }
                if prior?.phase != operation.phase || prior?.approved != operation.approved || prior?.acknowledgements != operation.acknowledgements {
                    candidate.lastEventSequence += 1
                    candidate.events.append(ManagedEvent(sequence: candidate.lastEventSequence, serviceId: operation.serviceId,
                                                        operationId: operation.id, kind: "operation." + operation.phase,
                                                        revision: operation.revision, date: now()))
                }
            }
        }
        candidate.events.removeAll { now().timeIntervalSince($0.date) > 30 * 86400 }
        var remaining = 10 * 1024 * 1024
        var retained: [ManagedEvent] = []
        for event in candidate.events.reversed() {
            let size = try JSONEncoder().encode(event).count
            guard size <= remaining else { break }
            retained.append(event); remaining -= size
        }
        candidate.events = retained.reversed()
        candidate.operations.removeAll { ["completed", "denied"].contains($0.phase) && now().timeIntervalSince($0.expires) > 30 * 86400 }
        candidate.replays = candidate.replays.filter { now().timeIntervalSince($0.value.date) <= 7 * 86400 }
        guard try ManagedDigest.canonical(candidate).count <= 32 * 1024 * 1024 else { throw ManagedError.recordTooLarge }
        do { try persistence.commit(candidate); state = candidate }
        catch { recoveryRequired = true; throw ManagedError.recoveryRequired }
    }
    /// No await exists between checking committed ownership, persisting the fence
    /// and the supervisor's final identity check + signal.
    public func cleanup(treeVerified: @Sendable (UUID) -> Bool = { _ in true }, signal: @Sendable (ManagedIncarnation) -> Bool) throws {
        guard !recoveryRequired else { throw ManagedError.recoveryRequired }
        guard state.maintenance == nil else { throw ManagedError.operationInProgress }
        for i in state.services.indices {
            let s = state.services[i]
            guard s.lifecycle == "release_pending", s.activeClaims.isEmpty, !s.keepRunning,
                  s.fence == nil, let began = releaseTimes[s.id], uptime() - began >= 60 else { continue }
            guard s.treeComplete, !s.incarnations.isEmpty, treeVerified(s.id) else { continue }
            // Polling may not yet have observed exit, PID reuse or loss of
            // identity access. Validate the complete target set before fencing.
            let liveTargets: [ManagedIncarnation]
            do { liveTargets = try requireLiveIncarnations(s) }
            catch {
                var candidate = state
                candidate.services[i].lifecycle = "needs_review"
                candidate.services[i].revision += 1
                candidate.revision += 1
                try commit(candidate)
                releaseTimes.removeValue(forKey: s.id)
                continue
            }
            var candidate = state; let operation = UUID()
            candidate.services[i].fence = operation; candidate.services[i].lifecycle = "stopping"
            candidate.operations.append(ManagedOperation(id: operation, serviceId: s.id, action: "stop", revision: s.revision,
                                                        targets: s.incarnations, generation: s.routeGeneration, actor: "helper",
                                                        phase: "fenced", expires: now()))
            candidate.revision += 1; try commit(candidate)
            var sent = true
            for target in liveTargets {
                guard identity(target.pid) == target, signal(target) else { sent = false; break }
            }
            if sent { signalTimes[s.id] = uptime() }
            candidate = state
            if let o = candidate.operations.firstIndex(where: { $0.id == operation }) {
                candidate.operations[o].phase = sent ? "signal_sent" : "needs_review"
            }
            if !sent { candidate.services[i].lifecycle = "needs_review"; candidate.services[i].fence = nil }
            // Signal delivery is not exit evidence; after a sent signal the fence remains until reconciled.
            candidate.revision += 1; try commit(candidate)
        }
    }
}
