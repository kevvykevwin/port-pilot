import XCTest
import Foundation
@testable import PortPilotCore

/// Helper-verified agent takeover of the export shutdown fence. Only process liveness (the injected identity
/// closure) and the clock are faked; the registry, sidecar and socket server are real.
final class ManagedPeerIdentityTests: XCTestCase, @unchecked Sendable {
    /// The fake process table. `set(nil)` means the PID is gone (the OS would report ESRCH);
    /// `unreadable` means the identity lookup fails while the process may still exist.
    private final class Live: @unchecked Sendable {
        private let lock = NSLock(); private var table: [Int32: ManagedIncarnation] = [:]; private var unreadableSet: Set<Int32> = []
        func set(_ i: ManagedIncarnation?, pid: Int32) { lock.withLock { table[pid] = i; unreadableSet.remove(pid) } }
        func unreadable(pid: Int32) { lock.withLock { table[pid] = nil; unreadableSet.insert(pid) } }
        func lookup(_ pid: Int32) -> ManagedIncarnation? { lock.withLock { table[pid] } }
        func gone(_ pid: Int32) -> Bool { lock.withLock { table[pid] == nil && !unreadableSet.contains(pid) } }
    }

    private struct Rig {
        let registry: ManagedRegistry; let disk: ManagedPersistence; let live: Live
        let enrollmentId: UUID; let epoch: Int; let control: (actor: String, token: String)
    }

    private let a = "instance-A-0123456789", b = "instance-B-0123456789"
    private func proc(_ pid: Int32, start: TimeInterval = 100) -> ManagedIncarnation {
        ManagedIncarnation(hostId: "h", bootId: "b", pid: pid, startTime: Date(timeIntervalSince1970: start))
    }
    private var actors: [ManagedActor] {
        [ManagedActor(id: "user", scope: .user, credentialHash: ManagedDigest.hash(Data("token-user".utf8)))]
    }

    private func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let disk = try ManagedPersistence(root: root)
        var state = ManagedState()
        var s = ManagedService(id: UUID(), workspace: ManagedWorkspace(id: UUID(), path: "/fixture/p", filesystemIdentity: "fs"),
                               name: "alpha", variant: "default", launchFingerprint: "fp")
        s.lifecycle = "running"; state.services = [s]; try disk.commit(state)
        let live = Live()
        let registry = ManagedRegistry(persistence: disk, actors: actors, identity: { live.lookup($0) }, isGone: { live.gone($0) })
        let r = await registry.handle(ManagedRequest(operation: "export.enroll", actor: "user", credential: "token-user", payload: [
            "services": .array([.string(s.id.uuidString)]), "destination": .string("Inbox"),
            "exportedFields": .array(ManagedNotificationContract.allowedFields.map { .string($0) }), "consent": .bool(true)]))
        guard case .object(let d)? = r.data, let path = d["credentialFile"]?.string else { throw XCTSkip("enroll failed") }
        let file = try JSONDecoder().decode(ManagedExportCredentialFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        return Rig(registry: registry, disk: disk, live: live, enrollmentId: UUID(uuidString: file.enrollmentId)!,
                   epoch: file.epoch, control: (file.control.actor, file.control.credential))
    }

    private func poll(_ r: Rig, _ instance: String, peer: ManagedIncarnation?, extra: [String: ManagedJSON] = [:]) async -> ManagedResponse {
        await r.registry.handle(ManagedRequest(operation: "export.control.poll", actor: r.control.actor, credential: r.control.token,
                                               payload: ["instance": .string(instance)].merging(extra) { $1 }), peer: peer)
    }
    private func ack(_ r: Rig, _ instance: String, challenge: String, peer: ManagedIncarnation? = nil) async -> ManagedResponse {
        await r.registry.handle(ManagedRequest(operation: "export.control.ack", actor: r.control.actor, credential: r.control.token,
            payload: ["instance": .string(instance), "epoch": .integer(r.epoch), "challenge": .string(challenge)]), peer: peer)
    }
    private func disable(_ r: Rig) async {
        let x = await r.registry.handle(ManagedRequest(operation: "export.disable", actor: "user", credential: "token-user",
                                                       payload: ["enrollmentId": .string(r.enrollmentId.uuidString)]))
        XCTAssertNil(x.error)
    }
    private func status(_ r: Rig) async -> [String: ManagedJSON] {
        let x = await r.registry.handle(ManagedRequest(operation: "export.status", actor: "user", credential: "token-user"))
        guard case .object(let d)? = x.data, case .array(let items)? = d["enrollments"], case .object(let o)? = items.last else { return [:] }
        return o
    }
    private func ok(_ x: ManagedResponse, line: UInt = #line) { XCTAssertNil(x.error, line: line) }
    private func challenge(_ x: ManagedResponse) -> String {
        if case .object(let d)? = x.data { return d["challenge"]?.string ?? "" }; return ""
    }

    func testHungAgentStillAliveBlocksTakeoverAndShutdownStaysUnconfirmed() async throws {
        // Bug caught: letting a successor confirm shutdown while the old agent process (possibly mid-send) is alive.
        let r = try await rig(); let x = proc(500)
        r.live.set(x, pid: 500)
        ok(await poll(r, a, peer: x))
        await disable(r)
        let denied = await poll(r, b, peer: proc(600))
        XCTAssertEqual(denied.error, .unauthorized)
        let ackDenied = await ack(r, b, challenge: "whatever")
        XCTAssertEqual(ackDenied.error, .unauthorized)
        let s = await status(r)
        XCTAssertEqual(s["shutdownConfirmed"], .bool(false)); XCTAssertEqual(s["agentTakeover"], .bool(false))
    }

    func testExitedAgentAllowsTakeoverAndOnlySuccessorConfirms() async throws {
        // Bug caught: a dead agent's restart being unable to confirm (stuck unconfirmed), or the old instance still acking.
        let r = try await rig(); let x = proc(500)
        r.live.set(x, pid: 500)
        ok(await poll(r, a, peer: x))
        await disable(r)
        r.live.set(nil, pid: 500)
        let taken = await poll(r, b, peer: proc(600))
        XCTAssertNil(taken.error)
        let ch = challenge(taken); XCTAssertFalse(ch.isEmpty)
        let old = await ack(r, a, challenge: ch)
        XCTAssertEqual(old.error, .unauthorized)
        ok(await ack(r, b, challenge: ch))
        let s = await status(r)
        XCTAssertEqual(s["display"], .string("disabled_shutdown_confirmed")); XCTAssertEqual(s["agentTakeover"], .bool(true))
        let later = await poll(r, a, peer: x)
        XCTAssertEqual(later.error, .unauthorized)
    }

    func testPidReuseWithDifferentStartTimeCountsAsExited() async throws {
        // Bug caught: treating a recycled PID as the original agent still being alive.
        let r = try await rig(); let x = proc(500, start: 100)
        r.live.set(x, pid: 500)
        ok(await poll(r, a, peer: x))
        await disable(r)
        r.live.set(proc(500, start: 999), pid: 500)
        ok(await poll(r, b, peer: proc(600)))
    }

    func testUnreadableIdentityOfLiveAgentBlocksTakeover() async throws {
        // Bug caught: a failed identity lookup (nil) treated as proof the registered agent exited, letting a
        // successor confirm shutdown while the predecessor may still be sending. Only a different identity at
        // the PID or an OS-confirmed ESRCH proves exit.
        let r = try await rig(); let x = proc(500)
        r.live.set(x, pid: 500)
        ok(await poll(r, a, peer: x))
        await disable(r)
        r.live.unreadable(pid: 500)
        let denied = await poll(r, b, peer: proc(600))
        XCTAssertEqual(denied.error, .unauthorized)
        let s = await status(r)
        XCTAssertEqual(s["shutdownConfirmed"], .bool(false)); XCTAssertEqual(s["agentTakeover"], .bool(false))
        r.live.set(nil, pid: 500)
        ok(await poll(r, b, peer: proc(600)))
    }

    func testRegistrationWithoutRecordedProcessCannotBeTakenOver() async throws {
        // Bug caught: takeover of a registration whose process was never proven (no peer identity at registration).
        let r = try await rig()
        ok(await poll(r, a, peer: nil))
        await disable(r)
        let denied = await poll(r, b, peer: proc(600))
        XCTAssertEqual(denied.error, .unauthorized)
    }

    func testSuccessorWithoutPeerIdentityCannotTakeOver() async throws {
        // Bug caught: accepting a successor whose own process the helper could not identify.
        let r = try await rig(); let x = proc(500)
        r.live.set(x, pid: 500)
        ok(await poll(r, a, peer: x))
        await disable(r); r.live.set(nil, pid: 500)
        let denied = await poll(r, b, peer: nil)
        XCTAssertEqual(denied.error, .unauthorized)
    }

    func testPeerIdentityInPayloadIsRejectedNotTrusted() async throws {
        // Bug caught: an agent-supplied "peer"/pid claim being accepted instead of failing strict payload validation.
        let r = try await rig()
        let x = await poll(r, a, peer: proc(500), extra: ["peer": .integer(1), "pid": .integer(1)])
        XCTAssertEqual(x.error, .invalidInput)
    }

    func testActiveReRegistrationUpdatesRecordedProcess() async throws {
        // Bug caught: a restarted agent keeping the stale recorded process, so its successor-in-waiting is judged against the dead one.
        let r = try await rig(); let x = proc(500), y = proc(600)
        r.live.set(x, pid: 500); r.live.set(y, pid: 600)
        ok(await poll(r, a, peer: x))
        ok(await poll(r, b, peer: y))
        await disable(r)
        // x is alive but irrelevant; y (the recorded one) is alive -> blocked. Then y exits -> allowed.
        let blocked = await poll(r, "instance-C-0123456789", peer: proc(700))
        XCTAssertEqual(blocked.error, .unauthorized)
        r.live.set(nil, pid: 600)
        ok(await poll(r, "instance-C-0123456789", peer: proc(700)))
    }

    func testOldSidecarWithoutRegisteredProcessDecodes() throws {
        // Bug caught: new optional fields breaking decode of sidecars written by the previous helper (PC18).
        let e = ManagedExportEnrollment(id: UUID(), epoch: 1, state: .revoked, selectedServices: [], destinationDescription: "d",
            exportedFields: [], refKey: "k", registeredInstance: "i", instanceRegisteredAt: nil, registeredProcess: nil, takeoverAt: nil,
            createdAt: Date(timeIntervalSince1970: 1), revokedAt: nil, shutdownChallenge: nil, acknowledgedAt: nil, controlRetired: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        object.removeValue(forKey: "registeredProcess"); object.removeValue(forKey: "takeoverAt")
        let decoded = try JSONDecoder().decode(ManagedExportEnrollment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.registeredProcess); XCTAssertNil(decoded.takeoverAt); XCTAssertEqual(decoded.registeredInstance, "i")
    }

    func testSocketServerPassesKernelReportedPeerPid() async throws {
        // Bug caught: peer identity missing/wrong (e.g. read from the payload or the wrong socket) so takeover can never or always pass.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        let server = try ManagedSocketServer(path: path) { request, peer in
            ManagedResponse(requestId: request.requestId, revision: 0, data: .object(["pid": .integer(Int(peer?.pid ?? -1))]))
        }
        Thread.detachNewThread { try? server.run() }
        let response = try ManagedSocket.request(ManagedRequest(operation: "status", actor: "x", credential: "y"), path: path)
        guard case .object(let d)? = response.data else { return XCTFail("no data") }
        XCTAssertEqual(d["pid"], .integer(Int(getpid())))
    }
}
