import XCTest
import Foundation
import Darwin
@testable import PortPilotCore

final class ManagedRegistryTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private var actors: [ManagedActor] {
        ["a", "b", "user", "bot", "reader"].map {
            ManagedActor(id: $0, scope: $0 == "user" ? .user : $0 == "bot" ? .coordinator : $0 == "reader" ? .read : .owner,
                         credentialHash: ManagedDigest.hash(Data("token-\($0)".utf8)))
        }
    }
    private func request(_ op: String, actor: String = "a", revision: Int? = 1,
                         service: UUID, payload: [String: ManagedJSON] = [:], id: String = UUID().uuidString) -> ManagedRequest {
        var payload = payload; payload["serviceId"] = .string(service.uuidString)
        return ManagedRequest(requestId: id, operation: op, actor: actor, credential: "token-\(actor)", expectedRevision: revision, payload: payload)
    }
    private func service() -> ManagedService {
        var value = ManagedService(id: UUID(), workspace: ManagedWorkspace(id: UUID(), path: "/tmp/fixture", filesystemIdentity: "test"),
                                   name: "web", variant: "default", launchFingerprint: "private")
        value.lifecycle = "running"
        value.claims = [ManagedClaim(id: UUID(), actor: "a", active: true, revision: 1)]
        value.incarnations = [ManagedIncarnation(hostId: "host", bootId: "boot", pid: 999999, startTime: Date(timeIntervalSince1970: 1000))]
        value.treeComplete = true
        return value
    }
    private func seed(_ service: ManagedService, root: URL) throws -> ManagedPersistence {
        let disk = try ManagedPersistence(root: root)
        var state = ManagedState(); state.services = [service]; try disk.commit(state)
        return disk
    }
    // Initial persisted services are conservatively needs_review after restart.
    // These tests create a fresh running service through the launch transition.
    private func running(root: URL, clock: TestClock = TestClock(), signal: SignalLog = SignalLog()) async throws -> (ManagedRegistry, ManagedService) {
        let registry = ManagedRegistry(persistence: try ManagedPersistence(root: root), actors: actors,
                                       uptime: { clock.time }, now: { clock.date }, identity: { _ in signal.identity },
                                       sendSignal: { identity, force in signal.record(identity, force: force); return true })
        let req = ManagedRequest(operation: "service.run", actor: "a", credential: "token-a", expectedRevision: 0)
        let service = try await registry.beginLaunch(req, workspace: ManagedWorkspace(id: UUID(), path: "/tmp/fixture", filesystemIdentity: "test"),
                                                    name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
        let identity = ManagedIncarnation(hostId: "host", bootId: "boot", pid: 999999, startTime: Date(timeIntervalSince1970: 1000))
        signal.identity = identity
        try await registry.recordChild(serviceId: service.id, incarnation: identity)
        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: true)
        return (registry, await registry.snapshot()[0])
    }
    func testO01UnregisteredServiceCannotBeStopped() async throws {
        let r = ManagedRegistry(persistence: try ManagedPersistence(root: directory()), actors: actors)
        let response = await r.handle(request("operation.propose", actor: "user", service: UUID(), payload: ["action": .string("stop")]))
        XCTAssertEqual(response.error, .needsDecision)
    }
    func testO05StaleRevisionAndO11ForgedOwner() async throws {
        let (r, s) = try await running(root: directory())
        let stale = await r.handle(request("claim.acquire", actor: "b", revision: s.revision - 1, service: s.id))
        XCTAssertEqual(stale.error, .staleRevision)
        let stolen = await r.handle(request("claim.release", actor: "b", revision: s.revision, service: s.id, payload: ["claimId": .string(s.claims[0].id.uuidString)]))
        XCTAssertEqual(stolen.error, .unauthorized)
        let snapshot = await r.snapshot()
        XCTAssertEqual(snapshot[0].activeClaims.count, 1)
    }
    func testClaimAndKeepRequireFreshIdentityBeforePolling() async throws {
        for missing in [false, true] {
            let log = SignalLog()
            let (registry, service) = try await running(root: directory(), signal: log)
            if missing { log.identity = nil }
            else { log.identity?.startTime = Date(timeIntervalSince1970: 2000) }
            let expected: ManagedError = missing ? .identityUnavailable : .staleIdentity
            let claim = await registry.handle(request("claim.acquire", actor: "b", revision: service.revision, service: service.id))
            XCTAssertEqual(claim.error, expected)
            let keep = await registry.handle(request("service.keep", actor: "user", revision: service.revision, service: service.id,
                                                     payload: ["keep": .bool(true)]))
            XCTAssertEqual(keep.error, expected)
            let unchanged = await registry.snapshot()[0]
            XCTAssertEqual(unchanged.revision, service.revision)
            XCTAssertEqual(unchanged.activeClaims.count, 1)
            XCTAssertFalse(unchanged.keepRunning)
        }
    }
    func testCleanupChecksIdentityBeforeFenceAndSignal() async throws {
        for missing in [false, true] {
            let clock = TestClock(); let log = SignalLog()
            let (registry, service) = try await running(root: directory(), clock: clock, signal: log)
            let released = await registry.handle(request("claim.release", revision: service.revision, service: service.id,
                                                         payload: ["claimId": .string(service.claims[0].id.uuidString)]))
            XCTAssertNil(released.error)
            clock.advance(60)
            if missing { log.identity = nil }
            else { log.identity?.bootId = "another-boot" }
            try await registry.cleanup { log.record($0, force: false); return true }
            XCTAssertEqual(log.count, 0)
            let reviewed = await registry.snapshot()[0]
            XCTAssertEqual(reviewed.lifecycle, "needs_review")
            XCTAssertNil(reviewed.fence)
            // Review cannot become a successful running claim on a dead process.
            let claim = await registry.handle(request("claim.acquire", actor: "b", revision: reviewed.revision, service: service.id))
            XCTAssertEqual(claim.error, .needsDecision)
        }
    }
    func testO10ReplayAndAuthorizationBeforeReplay() async throws {
        let (r, s) = try await running(root: directory())
        let req = request("claim.acquire", actor: "b", revision: s.revision, service: s.id, id: "retry")
        let first = await r.handle(req); let second = await r.handle(req)
        XCTAssertNil(first.error); XCTAssertEqual(first.revision, second.revision)
        var changed = req; changed.expectedRevision = 999
        let conflict = await r.handle(changed); XCTAssertEqual(conflict.error, .idempotencyConflict)
        changed = req; changed.actor = "a"; changed.credential = "token-a"
        let forbidden = await r.handle(changed); XCTAssertEqual(forbidden.error, .unauthorized)
        changed = req; changed.credential = "wrong"
        let invalid = await r.handle(changed); XCTAssertEqual(invalid.error, .unauthorized)
    }
    func testO06GraceKeepAndNewOwnerCancelCleanup() async throws {
        let clock = TestClock(); let log = SignalLog()
        let (r, s) = try await running(root: directory(), clock: clock, signal: log)
        let release = await r.handle(request("claim.release", revision: s.revision, service: s.id, payload: ["claimId": .string(s.claims[0].id.uuidString)]))
        clock.advance(59); try await r.cleanup { log.record($0, force: false); return true }
        XCTAssertEqual(log.count, 0)
        let keep = await r.handle(request("service.keep", actor: "user", revision: release.revision, service: s.id, payload: ["keep": .bool(true)]))
        XCTAssertNil(keep.error)
        clock.advance(100); try await r.cleanup { log.record($0, force: false); return true }; XCTAssertEqual(log.count, 0)
        let unkeep = await r.handle(request("service.keep", actor: "user", revision: keep.revision, service: s.id, payload: ["keep": .bool(false)]))
        clock.advance(59)
        let claim = await r.handle(request("claim.acquire", actor: "b", revision: unkeep.revision, service: s.id))
        XCTAssertNil(claim.error)
        clock.advance(100); try await r.cleanup { log.record($0, force: false); return true }; XCTAssertEqual(log.count, 0)
    }
    func testO05PostFenceClaimAndKeepCannotPromisePreservation() async throws {
        let clock = TestClock(); let log = SignalLog()
        let (r, s) = try await running(root: directory(), clock: clock, signal: log)
        let release = await r.handle(request("claim.release", revision: s.revision, service: s.id, payload: ["claimId": .string(s.claims[0].id.uuidString)]))
        clock.advance(60); try await r.cleanup { log.record($0, force: false); return true }
        XCTAssertEqual(log.count, 1)
        let claim = await r.handle(request("claim.acquire", actor: "b", revision: release.revision, service: s.id))
        XCTAssertEqual(claim.error, .operationInProgress)
        let keep = await r.handle(request("service.keep", actor: "user", revision: release.revision, service: s.id, payload: ["keep": .bool(true)]))
        XCTAssertEqual(keep.error, .operationInProgress)
    }
    func testO07FreshIdentityAndApprovalRequired() async throws {
        let log = SignalLog(); let (r, s) = try await running(root: directory(), signal: log)
        let proposal = await r.handle(request("operation.propose", actor: "user", revision: s.revision, service: s.id, payload: ["action": .string("stop")]))
        let operation = try XCTUnwrap(proposal.operationId)
        let payload: [String: ManagedJSON] = ["operationId": .string(operation.uuidString)]
        let denied = await r.handle(request("operation.execute", actor: "bot", revision: s.revision, service: s.id, payload: payload))
        XCTAssertEqual(denied.error, .needsDecision); XCTAssertEqual(log.count, 0)
        var approval = payload; approval["approved"] = .bool(true)
        let forged = await r.handle(request("decision.resolve", actor: "bot", revision: s.revision, service: s.id, payload: approval))
        XCTAssertEqual(forged.error, .unauthorized)
        let approved = await r.handle(request("decision.resolve", actor: "user", revision: s.revision, service: s.id, payload: approval))
        XCTAssertNil(approved.error)
        log.identity?.bootId = "new-boot"
        let stale = await r.handle(request("operation.execute", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertEqual(stale.error, .staleIdentity); XCTAssertEqual(log.count, 0)
    }
    func testO08ForceNeedsNewApprovalAfterGracefulSignal() async throws {
        let clock = TestClock(); let log = SignalLog()
        let (r, s) = try await running(root: directory(), clock: clock, signal: log)
        let propose = await r.handle(request("operation.propose", actor: "user", revision: s.revision, service: s.id, payload: ["action": .string("stop")]))
        let stop = try XCTUnwrap(propose.operationId)
        var payload: [String: ManagedJSON] = ["operationId": .string(stop.uuidString), "approved": .bool(true)]
        _ = await r.handle(request("decision.resolve", actor: "user", revision: s.revision, service: s.id, payload: payload))
        _ = await r.handle(request("operation.execute", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertEqual(log.count, 1)
        let early = await r.handle(request("operation.propose", actor: "user", revision: s.revision, service: s.id, payload: ["action": .string("force")]))
        XCTAssertEqual(early.error, .operationInProgress)
        clock.advance(2)
        let force = await r.handle(request("operation.propose", actor: "user", revision: s.revision, service: s.id, payload: ["action": .string("force")]))
        let forceId = try XCTUnwrap(force.operationId)
        payload["operationId"] = .string(forceId.uuidString)
        let noApproval = await r.handle(request("operation.execute", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertEqual(noApproval.error, .needsDecision); XCTAssertEqual(log.count, 1)
        let approved = await r.handle(request("decision.resolve", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertNil(approved.error)
        let sent = await r.handle(request("operation.execute", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertNil(sent.error); XCTAssertEqual(log.count, 2)
    }
    func testClockRollbackInvalidatesApproval() async throws {
        let clock = TestClock(); let (r, s) = try await running(root: directory(), clock: clock)
        let proposed = await r.handle(request("operation.propose", actor: "user", revision: s.revision, service: s.id, payload: ["action": .string("stop")]))
        let id = try XCTUnwrap(proposed.operationId)
        let payload: [String: ManagedJSON] = ["operationId": .string(id.uuidString), "approved": .bool(true)]
        let approve = await r.handle(request("decision.resolve", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertNil(approve.error)
        clock.wallOffset = -3600
        let response = await r.handle(request("operation.execute", actor: "user", revision: s.revision, service: s.id, payload: payload))
        XCTAssertEqual(response.error, .staleRevision)
    }
    func testO09CorruptionPreservedAndSingleton() async throws {
        let root = try directory(); let disk = try ManagedPersistence(root: root)
        let bytes = Data("{corrupt".utf8); try disk.write("registry.json", data: bytes)
        XCTAssertThrowsError(try ManagedPersistence(root: root))
        let r = ManagedRegistry(persistence: disk, actors: actors)
        let result = await r.handle(request("claim.acquire", service: UUID()))
        XCTAssertEqual(result.error, .recoveryRequired)
        XCTAssertEqual(try disk.read("registry.json"), bytes)
    }
    func testUnknownSchemaAndInterruptedCommitRemainReadOnly() async throws {
        for schema in [1, 99] {
            let root = try directory(); let disk = try ManagedPersistence(root: root)
            var state = ManagedState(); state.schema = schema
            try disk.commit(state)
            if schema == 1 { state.revision += 1; try disk.write("intent.json", data: JSONEncoder().encode(state)) }
            let r = ManagedRegistry(persistence: disk, actors: actors)
            let result = await r.handle(request("claim.acquire", service: UUID()))
            XCTAssertEqual(result.error, .recoveryRequired)
        }
    }
    func testO10ReplaySurvivesRestart() async throws {
        let root = try directory()
        var r: ManagedRegistry?; var disk: ManagedPersistence? = try ManagedPersistence(root: root)
        let s = service(); var state = ManagedState(); state.services = [s]
        let req = request("claim.release", service: s.id, id: "persisted")
        state.replays[req.requestId] = ManagedReplay(actor: "a", digest: ManagedDigest.hash(try ManagedDigest.canonical(req)),
                                                    response: ManagedResponse(requestId: req.requestId, revision: 99), date: Date())
        try disk!.commit(state); disk = nil
        r = ManagedRegistry(persistence: try ManagedPersistence(root: root), actors: actors)
        let response = await r!.handle(req); XCTAssertEqual(response.revision, 99); XCTAssertNil(response.error)
        r = nil
    }
    func testO02WorkspaceAliasAndRecreationAndO03ConfigurationContent() throws {
        let root = try directory(); let config = root.appendingPathComponent("config")
        try Data("one".utf8).write(to: config)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        var launch = ManagedLaunch(service: "web", executable: "/usr/bin/true", arguments: ["{port}"], cwd: root.path,
                                   configurationFiles: [config.path])
        let original = try launch.workspace(); let digest = try launch.fingerprint(key: Data("key".utf8))
        launch.cwd = alias.path; XCTAssertEqual(try launch.workspace().filesystemIdentity, original.filesystemIdentity)
        launch.cwd = root.path
        try Data("two".utf8).write(to: config)
        XCTAssertNotEqual(try launch.fingerprint(key: Data("key".utf8)), digest)
        try FileManager.default.removeItem(at: config)
        XCTAssertThrowsError(try launch.fingerprint(key: Data("key".utf8)))
    }
    func testReportsOmitLocalFingerprint() async throws {
        let (r, s) = try await running(root: directory())
        let response = await r.handle(request("service.inspect", actor: "reader", service: s.id))
        let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(text.contains("launchFingerprint")); XCTAssertFalse(text.contains("private"))
    }
    func testO13AdoptionRejectsReusedPIDAndRequiresUserCredential() async throws {
        let log = SignalLog(); log.identity = service().incarnations[0]
        let r = ManagedRegistry(persistence: try ManagedPersistence(root: directory()), actors: actors, identity: { _ in log.identity })
        let workspace = service().workspace; let target = try XCTUnwrap(log.identity)
        let owner = request("service.adopt", revision: 0, service: UUID())
        do {
            _ = try await r.adopt(owner, workspace: workspace, name: "db", variant: "default", target: target, port: 30001)
            XCTFail("owner credential must not authorize adoption")
        } catch { XCTAssertEqual(error as? ManagedError, .unauthorized) }
        let user = request("service.adopt", actor: "user", revision: 0, service: UUID())
        log.identity?.startTime = Date(timeIntervalSince1970: 2000)
        do {
            _ = try await r.adopt(user, workspace: workspace, name: "db", variant: "default", target: target, port: 30001)
            XCTFail("reused PID adopted")
        } catch { XCTAssertEqual(error as? ManagedError, .staleIdentity) }
        log.identity = target
        let response = try await r.adopt(user, workspace: workspace, name: "db", variant: "default", target: target, port: 30001)
        XCTAssertNil(response.error)
        let services = await r.snapshot()
        XCTAssertFalse(services[0].treeComplete); XCTAssertNil(services[0].stablePort)
    }
    func testCommitFailurePreventsLaunchAndPreservesRecoveryJournal() async throws {
        let root = try directory()
        let disk = try ManagedPersistence(root: root, writeFault: { $0 == "registry.json" })
        let r = ManagedRegistry(persistence: disk, actors: actors)
        let req = ManagedRequest(operation: "service.run", actor: "a", credential: "token-a", expectedRevision: 0)
        do {
            _ = try await r.beginLaunch(req, workspace: service().workspace, name: "web", variant: "default", fingerprint: "private", backend: 30001, stable: 20001)
            XCTFail("launch accepted without durable snapshot")
        } catch { XCTAssertEqual(error as? ManagedError, .recoveryRequired) }
        XCTAssertNotNil(try disk.read("intent.json")); XCTAssertNil(try disk.read("registry.json"))
        let state = await r.snapshot(); XCTAssertTrue(state.isEmpty)
        let denied = await r.handle(request("claim.acquire", service: UUID()))
        XCTAssertEqual(denied.error, .recoveryRequired)
    }
    func testPaginationCapsRecordsAndRejectsWrongTypesAndStaleCursor() async throws {
        let disk = try ManagedPersistence(root: directory()); var state = ManagedState()
        for _ in 0..<201 { state.services.append(service()) }
        try disk.commit(state)
        let r = ManagedRegistry(persistence: disk, actors: actors)
        let first = await r.handle(request("services.list", service: UUID(), payload: ["limit": .integer(201)]))
        guard case .object(let page) = first.data, case .array(let records) = page["records"], let cursor = page["cursor"]?.string else { return XCTFail("missing page") }
        XCTAssertEqual(records.count, 200)
        let second = await r.handle(request("services.list", service: UUID(), payload: ["cursor": .string(cursor)]))
        guard case .object(let last) = second.data, case .array(let remaining) = last["records"] else { return XCTFail("missing last page") }
        XCTAssertEqual(remaining.count, 1)
        let wrong = await r.handle(request("services.list", service: UUID(), payload: ["limit": .string("200")]))
        XCTAssertEqual(wrong.error, .invalidInput)
        let changed = await r.handle(request("operation.propose", actor: "user", service: state.services[0].id, payload: ["action": .string("stop")]))
        XCTAssertNil(changed.error)
        let stale = await r.handle(request("services.list", service: UUID(), payload: ["cursor": .string(cursor)]))
        XCTAssertEqual(stale.error, .staleRevision)
    }
    func testOversizedSingleRecordReturnsTypedError() async throws {
        let disk = try ManagedPersistence(root: directory()); var state = ManagedState(); var s = service()
        s.workspace.path = String(repeating: "x", count: ManagedWire.responseLimit)
        state.services = [s]; try disk.commit(state)
        let r = ManagedRegistry(persistence: disk, actors: actors)
        let response = await r.handle(request("services.list", service: UUID()))
        XCTAssertEqual(response.error, .recordTooLarge)
    }
    func testHelperProxyIsInfrastructureNotADevelopmentServer() {
        let entry = PortEntry(pid: 1, port: 20001, processName: "PortPilotHelper", executablePath: "/tmp/PortPilotHelper", protocol: .tcp,
                              state: .listen, family: .ipv4, localAddress: "127.0.0.1", processStartTime: Date(), projectPath: "/tmp/project")
        XCTAssertEqual(ProcessClassifier.classify(entry).category, .infrastructure)
    }
    func testEventCursorSurvivesRevisionChangesAndReportsExpiredHistory() async throws {
        let disk = try ManagedPersistence(root: directory()); var state = ManagedState(); let s = service()
        state.services = [s]; state.lastEventSequence = 1
        state.events = [ManagedEvent(sequence: 1, serviceId: s.id, kind: "old", revision: 1, date: .distantPast)]
        try disk.commit(state)
        let r = ManagedRegistry(persistence: disk, actors: actors)
        let changed = await r.handle(request("operation.propose", actor: "user", service: s.id, payload: ["action": .string("stop")]))
        XCTAssertNil(changed.error)
        let cursor = Data("events:1".utf8).base64EncodedString()
        let resumed = await r.handle(request("events.list", service: s.id, payload: ["cursor": .string(cursor)]))
        XCTAssertNil(resumed.error)
        guard case .object(let page) = resumed.data, case .array(let events) = page["records"] else { return XCTFail("missing events") }
        XCTAssertEqual(events.count, 1)
        let expired = await r.handle(request("events.list", service: s.id, payload: ["cursor": .string(Data("events:0".utf8).base64EncodedString())]))
        XCTAssertEqual(expired.error, .resyncRequired)
    }
    func testLaunchValidationRejectsControlCharactersAndNamesOutsideContract() throws {
        for name in ["", "web\n", "WEB", "-web", String(repeating: "x", count: 41), "日本"] {
            XCTAssertFalse(ManagedServiceName.isValid(name))
        }
        XCTAssertTrue(ManagedServiceName.isValid("web-2"))
        var launch = ManagedLaunch(service: "web", executable: "/usr/bin/true", arguments: ["{port}"], cwd: "/tmp")
        for path in ["//outside", "/health\r\n", "/health?token=secret", "", "/a b"] {
            launch.readinessPath = path
            XCTAssertThrowsError(try launch.validate())
        }
    }
    func testO14DuplicateKeysIncludingEscapedKeysAndInvalidTypes() throws {
        for json in [#"{"actor":"a","\u0061ctor":"b"}"#, #"{"nested":{"x":1,"x":2}}"#, "[]", "{}", #"{"protocolVersion":"1"}"#] {
            XCTAssertThrowsError(try ManagedWire.decode(Data(json.utf8)))
        }
        XCTAssertThrowsError(try ManagedWire.decode(Data([0xff])))
        let req = ManagedRequest(operation: "status", actor: "a", credential: "token")
        let data = try JSONEncoder().encode(req)
        XCTAssertEqual(try ManagedWire.decode(data).actor, "a")
        var maximum = data; maximum.append(Data(repeating: 32, count: 65536 - data.count))
        XCTAssertNoThrow(try ManagedWire.decode(maximum))
        maximum.append(32); XCTAssertThrowsError(try ManagedWire.decode(maximum))
        var unsupported = req; unsupported.protocolVersion = 99
        XCTAssertThrowsError(try ManagedWire.decode(JSONEncoder().encode(unsupported))) { XCTAssertEqual($0 as? ManagedError, .protocolMismatch) }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var offset: TimeInterval = 0
    var time: TimeInterval { lock.withLock { elapsed } }
    var date: Date { lock.withLock { Date(timeIntervalSince1970: 10000 + elapsed + offset) } }
    var wallOffset: TimeInterval { get { lock.withLock { offset } } set { lock.withLock { offset = newValue } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
}
private final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ManagedIncarnation?
    private var signals = 0
    var identity: ManagedIncarnation? { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
    var count: Int { lock.withLock { signals } }
    func record(_ identity: ManagedIncarnation, force: Bool) { lock.withLock { signals += 1 } }
}
