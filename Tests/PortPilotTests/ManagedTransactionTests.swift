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
