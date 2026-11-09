import XCTest
import Foundation
@testable import PortPilotCore

final class ManagedTransactionTests: XCTestCase, @unchecked Sendable {
    private func disk() throws -> ManagedPersistence {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pp-txn-\(UUID().uuidString)")
        let disk = try ManagedPersistence(root: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return disk
    }
    private var actors: [ManagedActor] {
        [ManagedActor(id: "user", scope: .user, credentialHash: ManagedDigest.hash(Data("secret".utf8))),
         ManagedActor(id: "owner", scope: .owner, credentialHash: ManagedDigest.hash(Data("secret".utf8))),
         ManagedActor(id: "reader", scope: .read, credentialHash: ManagedDigest.hash(Data("secret".utf8)))]
    }
    private func request(_ operation: String, actor: String = "user", service: ManagedService? = nil, payload: [String: ManagedJSON] = [:]) -> ManagedRequest {
        var values = payload
        if let service { values["serviceId"] = .string(service.id.uuidString) }
        return ManagedRequest(operation: operation, actor: actor, credential: "secret", expectedRevision: service?.revision ?? 0, payload: values)
    }
    private func live(_ pid: Int32) -> ManagedIncarnation {
        ManagedIncarnation(hostId: "fixture", bootId: "boot", pid: pid, startTime: Date(timeIntervalSince1970: Double(pid)))
    }
    private func running() async throws -> (ManagedRegistry, ManagedService) {
        let old = live(999991), new = live(999992)
        let registry = ManagedRegistry(persistence: try disk(), actors: actors, identity: { $0 == old.pid ? old : $0 == new.pid ? new : nil })
        let service = try await registry.beginLaunch(request("service.run", actor: "owner"), workspace: ManagedWorkspace(id: UUID(), path: "/tmp", filesystemIdentity: "fixture"),
            name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
        try await registry.recordChild(serviceId: service.id, incarnation: old)
        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: false)
        return (registry, await registry.snapshot()[0])
    }
    private func proposed(_ registry: ManagedRegistry, _ service: ManagedService) async throws -> UUID {
        let response = await registry.handle(request("operation.propose", service: service, payload: ["action": .string("reroute")]))
        XCTAssertNil(response.error)
        return try XCTUnwrap(response.operationId)
    }
    func testRerouteRequiresOwnerAcknowledgementAndRechecksRevisionAtCutover() async throws {
        let (registry, service) = try await running()
        let id = try await proposed(registry, service)
        let execute = request("operation.execute", service: service, payload: ["operationId": .string(id.uuidString)])
        do { _ = try await registry.beginReroute(execute, backend: 30002); XCTFail("Unanswered owner cannot authorize move") }
        catch { XCTAssertEqual(error as? ManagedError, .needsDecision) }
        let ack = await registry.handle(request("operation.acknowledge", actor: "owner", service: service, payload: ["operationId": .string(id.uuidString)]))
        XCTAssertNil(ack.error)
        let accepted = try await registry.beginReroute(execute, backend: 30002)
        XCTAssertEqual(accepted.status, "accepted")
        try await registry.recordReplacement(serviceId: service.id, operationId: id, targets: [live(999992)])
        let claim = await registry.handle(request("claim.acquire", service: service))
        XCTAssertNil(claim.error)
        let switches = RouteSwitches()
        do {
            try await registry.switchReroute(serviceId: service.id, operationId: id) { switches.append($0, $1) }
            XCTFail("New owner must invalidate prior acknowledgement")
        } catch { XCTAssertEqual(error as? ManagedError, .staleRevision) }
        XCTAssertTrue(switches.values.isEmpty)
        let snapshot = await registry.snapshot()[0]
        XCTAssertNil(snapshot.fence)
        XCTAssertEqual(snapshot.backendPort, 30001)
    }
    func testFencedCutoverRollbackPreservesClaimsAndBothProcessIdentities() async throws {
        let (registry, service) = try await running()
        let id = try await proposed(registry, service)
        let approve = await registry.handle(request("decision.resolve", service: service, payload: ["operationId": .string(id.uuidString), "approved": .bool(true)]))
        XCTAssertNil(approve.error)
        _ = try await registry.beginReroute(request("operation.execute", service: service, payload: ["operationId": .string(id.uuidString)]), backend: 30002)
        try await registry.recordReplacement(serviceId: service.id, operationId: id, targets: [live(999992)])
        let switches = RouteSwitches()
        try await registry.switchReroute(serviceId: service.id, operationId: id) { switches.append($0, $1) }
        let switched = await registry.snapshot()[0]
        XCTAssertEqual(switched.backendPort, 30002)
        XCTAssertEqual(switched.fence, id)
        let late = await registry.handle(request("claim.acquire", service: switched))
        XCTAssertEqual(late.error, .operationInProgress)
        try await registry.rollbackReroute(serviceId: service.id, operationId: id) { switches.append($0, $1) }
        let restored = await registry.snapshot()[0]
        XCTAssertEqual(restored.backendPort, 30001)
        XCTAssertEqual(restored.routeGeneration, 3)
        XCTAssertEqual(restored.activeClaims.map(\.id), service.activeClaims.map(\.id))
        XCTAssertEqual(restored.incarnations.count, 2)
        XCTAssertNil(restored.fence)
        XCTAssertEqual(switches.values.map { $0.0 }, [30002, 30001])
        let operation = await registry.operation(id: id)
        XCTAssertEqual(operation?.outcome, "rolled_back_replacement_retained_for_review")
        XCTAssertEqual(operation?.phase, "needs_review")
    }
    /// Reaches switched -> finishReroute(retained) where the new backend root sits at index 1.
    private func retainedReroute(identities: Ident) async throws -> (ManagedRegistry, ManagedService, UUID) {
        let old = live(999991), new = live(999992)
        let registry = ManagedRegistry(persistence: try disk(), actors: actors, identity: { identities.lookup($0) },
                                       isGone: { identities.isGone($0) })
        identities.start(old); identities.start(new)
        let service = try await registry.beginLaunch(request("service.run", actor: "owner"), workspace: ManagedWorkspace(id: UUID(), path: "/tmp", filesystemIdentity: "fixture"),
            name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
        try await registry.recordChild(serviceId: service.id, incarnation: old)
        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: false)
        let running = await registry.snapshot()[0]
        let id = try await proposed(registry, running)
        let approve = await registry.handle(request("decision.resolve", service: running, payload: ["operationId": .string(id.uuidString), "approved": .bool(true)]))
        XCTAssertNil(approve.error)
        _ = try await registry.beginReroute(request("operation.execute", service: running, payload: ["operationId": .string(id.uuidString)]), backend: 30002)
        try await registry.recordReplacement(serviceId: running.id, operationId: id, targets: [new])
        try await registry.switchReroute(serviceId: running.id, operationId: id) { _, _ in }
        try await registry.finishReroute(serviceId: running.id, operationId: id, outcome: "route_verified_old_tree_retained_for_review")
        return (registry, await registry.snapshot()[0], id)
    }
    func testNewBackendRootExitAfterRetainedRerouteIsNeedsReviewNotPruned() async throws {
        let ids = Ident()
        let (registry, service, _) = try await retainedReroute(identities: ids)
        XCTAssertEqual(service.lifecycle, "running"); XCTAssertNotNil(service.transition); XCTAssertNil(service.fence)
        XCTAssertEqual(service.incarnations, [live(999991), live(999992)])
        ids.exit(live(999992))   // the new backend root crashes
        try await registry.reconcileStops()
        let after = await registry.snapshot()[0]
        XCTAssertEqual(after.lifecycle, "needs_review")
        XCTAssertEqual(after.incarnations, [live(999991), live(999992)], "the dead new root must not be pruned")
    }
    func testRestartFromNeedsReviewWithTransitionRequiresOldAndNewTargetsGone() async throws {
        let ids = Ident()
        let (registry, service, _) = try await retainedReroute(identities: ids)
        ids.exit(live(999992))
        try await registry.reconcileStops()
        let review = await registry.snapshot()[0]
        XCTAssertEqual(review.lifecycle, "needs_review")
        let rerun = ManagedRequest(operation: "service.run", actor: "owner", credential: "secret", expectedRevision: review.revision)
        // old backend still alive
        do { _ = try await registry.restartLaunch(rerun, serviceId: service.id, fingerprint: "private", backend: 30003); XCTFail("old target alive") }
        catch { XCTAssertEqual(error as? ManagedError, .incompatibleLaunch) }
        ids.exit(live(999991))
        let restarted = try await registry.restartLaunch(rerun, serviceId: service.id, fingerprint: "private", backend: 30003)
        XCTAssertEqual(restarted.lifecycle, "starting")
        XCTAssertNil(restarted.transition, "the stale route transition must be cleared on restart")
    }
    func testRestartFromNeedsReviewRejectedWhileNewTargetAliveInTransitionOnly() async throws {
        // A transition target that is not in incarnations (preparing-phase leftover) still blocks restart.
        let ids = Ident()
        let old = live(999991), new = live(999992)
        let registry = ManagedRegistry(persistence: try disk(), actors: actors, identity: { ids.lookup($0) }, isGone: { ids.isGone($0) })
        ids.start(old); ids.start(new)
        let service = try await registry.beginLaunch(request("service.run", actor: "owner"), workspace: ManagedWorkspace(id: UUID(), path: "/tmp", filesystemIdentity: "fixture"),
            name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
        try await registry.recordChild(serviceId: service.id, incarnation: old)
        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: false)
        let running = await registry.snapshot()[0]
        let id = try await proposed(registry, running)
        _ = await registry.handle(request("decision.resolve", service: running, payload: ["operationId": .string(id.uuidString), "approved": .bool(true)]))
        _ = try await registry.beginReroute(request("operation.execute", service: running, payload: ["operationId": .string(id.uuidString)]), backend: 30002)
        try await registry.recordReplacement(serviceId: running.id, operationId: id, targets: [new])
        // Preparation failed: finishReroute retains the replacement in incarnations; drop old, keep new alive.
        try await registry.finishReroute(serviceId: running.id, operationId: id, outcome: "replacement_not_ready")
        ids.exit(old)
        let rerun = ManagedRequest(operation: "service.run", actor: "owner", credential: "secret", expectedRevision: await registry.snapshot()[0].revision)
        try await registry.reconcileStops()
        let review = await registry.snapshot()[0]
        XCTAssertEqual(review.lifecycle, "needs_review")
        var request = rerun; request.expectedRevision = review.revision
        do { _ = try await registry.restartLaunch(request, serviceId: service.id, fingerprint: "private", backend: 30003); XCTFail("new target alive") }
        catch { XCTAssertEqual(error as? ManagedError, .incompatibleLaunch) }
    }
    /// Bug caught: switchReroute committed phase "ready" plus the fence, then threw staleIdentity on its post-commit
    /// identity re-check and left both in place, so abandonReplacement (preparing only) refused and the still-serving
    /// old backend ended up needs_review and unstoppable.
    func testSwitchRerouteIdentityFailureAfterFenceRevertsToPreparingSoReplacementCanBeAbandoned() async throws {
        let ids = Ident()
        let old = live(999991), new = live(999992)
        let newLookups = LookupCounter()
        let registry = ManagedRegistry(persistence: try disk(), actors: actors, identity: { pid in
            if pid == new.pid, newLookups.next() > 2 { return self.live(999993) }   // recordReplacement, switchReroute guard, then mismatch
            return ids.lookup(pid)
        }, isGone: { ids.isGone($0) })
        ids.start(old); ids.start(new)
        let service = try await registry.beginLaunch(request("service.run", actor: "owner"), workspace: ManagedWorkspace(id: UUID(), path: "/tmp", filesystemIdentity: "fixture"),
            name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
        try await registry.recordChild(serviceId: service.id, incarnation: old)
        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: false)
        let running = await registry.snapshot()[0]
        let id = try await proposed(registry, running)
        _ = await registry.handle(request("decision.resolve", service: running, payload: ["operationId": .string(id.uuidString), "approved": .bool(true)]))
        _ = try await registry.beginReroute(request("operation.execute", service: running, payload: ["operationId": .string(id.uuidString)]), backend: 30002)
        try await registry.recordReplacement(serviceId: running.id, operationId: id, targets: [new])
        let switches = RouteSwitches()
        do { try await registry.switchReroute(serviceId: running.id, operationId: id) { switches.append($0, $1) }; XCTFail("identity changed") }
        catch { XCTAssertEqual(error as? ManagedError, .staleIdentity) }
        XCTAssertTrue(switches.values.isEmpty, "route must not have been switched")
        let reverted = await registry.snapshot()[0]
        XCTAssertEqual(reverted.transition?.phase, "preparing")
        XCTAssertNil(reverted.fence)
        XCTAssertEqual(reverted.backendPort, 30001)
        let op = await registry.operation(id: id)
        XCTAssertEqual(op?.phase, "preparing")
        ids.exit(new)
        try await registry.abandonReplacement(serviceId: running.id, operationId: id, outcome: "preparation_failed_replacement_stopped")
        let after = await registry.snapshot()[0]
        XCTAssertNil(after.transition); XCTAssertEqual(after.incarnations, [old]); XCTAssertEqual(after.lifecycle, "running")
    }
    /// Bug caught: loosening abandonReplacement to accept a transition past "preparing" would drop a switched route's
    /// bookkeeping while traffic already goes to the replacement.
    func testAbandonReplacementRefusesOutsidePreparingPhase() async throws {
        let (registry, service, id) = try await retainedReroute(identities: Ident())
        do { try await registry.abandonReplacement(serviceId: service.id, operationId: id, outcome: "x"); XCTFail("phase is not preparing") }
        catch { XCTAssertEqual(error as? ManagedError, .staleRevision) }
    }
    /// Bug caught: abandoning a failed replacement merged its (dead) root into incarnations or left the transition open,
    /// and accepting it while the replacement still runs would orphan a live process.
    func testAbandonReplacementRequiresNewTargetsProvenExitedAndKeepsOldIncarnations() async throws {
        let ids = Ident()
        let old = live(999991), new = live(999992)
        let registry = ManagedRegistry(persistence: try disk(), actors: actors, identity: { ids.lookup($0) }, isGone: { ids.isGone($0) })
        ids.start(old); ids.start(new)
        let service = try await registry.beginLaunch(request("service.run", actor: "owner"), workspace: ManagedWorkspace(id: UUID(), path: "/tmp", filesystemIdentity: "fixture"),
            name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
        try await registry.recordChild(serviceId: service.id, incarnation: old)
        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: false)
        let running = await registry.snapshot()[0]
        let id = try await proposed(registry, running)
        _ = await registry.handle(request("decision.resolve", service: running, payload: ["operationId": .string(id.uuidString), "approved": .bool(true)]))
        _ = try await registry.beginReroute(request("operation.execute", service: running, payload: ["operationId": .string(id.uuidString)]), backend: 30002)
        try await registry.recordReplacement(serviceId: running.id, operationId: id, targets: [new])
        do { try await registry.abandonReplacement(serviceId: running.id, operationId: id, outcome: "preparation_failed_replacement_stopped"); XCTFail("replacement still alive") }
        catch { XCTAssertEqual(error as? ManagedError, .needsDecision) }
        let untouched = await registry.snapshot()[0]
        XCTAssertNotNil(untouched.transition)
        // Refuses when another operation holds the fence (the guard must not let it clear someone else's fence).
        let other = UUID()
        try await registry.setFenceForTesting(serviceId: running.id, operation: other)
        do { try await registry.abandonReplacement(serviceId: running.id, operationId: id, outcome: "x"); XCTFail("other op holds fence") }
        catch { XCTAssertEqual(error as? ManagedError, .operationInProgress) }
        try await registry.setFenceForTesting(serviceId: running.id, operation: nil)
        ids.exit(new)
        try await registry.abandonReplacement(serviceId: running.id, operationId: id, outcome: "preparation_failed_replacement_stopped")
        let after = await registry.snapshot()[0]
        XCTAssertNil(after.transition); XCTAssertNil(after.fence)
        XCTAssertEqual(after.lifecycle, "running")
        XCTAssertEqual(after.incarnations, [old])
        XCTAssertEqual(after.backendPort, 30001)
        XCTAssertGreaterThan(after.revision, running.revision)
        let operation = await registry.operation(id: id)
        XCTAssertEqual(operation?.phase, "needs_review")
        XCTAssertEqual(operation?.outcome, "preparation_failed_replacement_stopped")
        try await registry.reconcileStops()
        let reconciled = await registry.snapshot()[0]
        XCTAssertEqual(reconciled.lifecycle, "running", "reconcile must leave the old backend alone")
        do { try await registry.abandonReplacement(serviceId: running.id, operationId: id, outcome: "x"); XCTFail("transition already cleared") }
        catch { XCTAssertEqual(error as? ManagedError, .staleRevision) }
    }
    func testQuiescenceRequiresNoLiveChildrenAndSurvivesRestart() async throws {
        let (active, _) = try await running()
        let deferred = await active.handle(request("lifecycle.quiesce"))
        XCTAssertEqual(deferred.error, .needsDecision)
        let storage = try disk()
        let registry = ManagedRegistry(persistence: storage, actors: actors)
        let denied = await registry.handle(request("lifecycle.quiesce", actor: "owner"))
        XCTAssertEqual(denied.error, .unauthorized)
        let quiesce = request("lifecycle.quiesce")
        let response = await registry.handle(quiesce)
        XCTAssertNil(response.error)
        let restarted = ManagedRegistry(persistence: storage, actors: actors)
        let status = await restarted.handle(request("status", actor: "reader"))
        guard case .object(let values) = status.data else { return XCTFail("missing status") }
        XCTAssertEqual(values["mutationsEnabled"], .bool(false))
        XCTAssertEqual(values["checkpoint"], .string(quiesce.requestId))
        let blocked = await restarted.preflight(request("service.run"))
        XCTAssertEqual(blocked?.error, .operationInProgress)
        let wrong = await restarted.handle(request("lifecycle.resume", payload: ["checkpoint": .string("wrong")]))
        XCTAssertEqual(wrong.error, .staleRevision)
        let resumed = await restarted.handle(request("lifecycle.resume", payload: ["checkpoint": .string(quiesce.requestId)]))
        XCTAssertNil(resumed.error)
        let after = await restarted.preflight(request("service.run"))
        XCTAssertNil(after)
    }
    func testPendingDecisionsReadableWithoutWriteAuthority() async throws {
        let (registry, service) = try await running()
        let id = try await proposed(registry, service)
        let response = await registry.handle(request("operations.list", actor: "reader"))
        guard case .object(let page) = response.data, case .array(let records) = page["records"] else { return XCTFail("missing operations") }
        let operations = try records.map { try JSONDecoder().decode(ManagedOperation.self, from: JSONEncoder().encode($0)) }
        XCTAssertTrue(operations.contains { $0.id == id && $0.phase == "proposed" })
        let forged = await registry.handle(request("decision.resolve", actor: "reader", service: service, payload: ["operationId": .string(id.uuidString), "approved": .bool(true)]))
        XCTAssertEqual(forged.error, .unauthorized)
    }
}

private final class RouteSwitches: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(UInt16, Int)] = []
    var values: [(UInt16, Int)] { lock.withLock { storage } }
    func append(_ port: UInt16, _ generation: Int) { lock.withLock { storage.append((port, generation)) } }
}

private final class Ident: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: ManagedIncarnation] = [:]
    private var gone: Set<Int32> = []
    func start(_ i: ManagedIncarnation) { lock.withLock { table[i.pid] = i; gone.remove(i.pid) } }
    func exit(_ i: ManagedIncarnation) { lock.withLock { table[i.pid] = nil; gone.insert(i.pid) } }
    func lookup(_ pid: Int32) -> ManagedIncarnation? { lock.withLock { table[pid] } }
    func isGone(_ pid: Int32) -> Bool { lock.withLock { gone.contains(pid) } }
}

private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

extension ManagedRegistry {
    func setFenceForTesting(serviceId: UUID, operation: UUID?) throws {
        guard let i = state.services.firstIndex(where: { $0.id == serviceId }) else { return }
        state.services[i].fence = operation
    }
}
