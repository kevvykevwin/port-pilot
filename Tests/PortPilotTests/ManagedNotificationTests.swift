import XCTest
import Foundation
@testable import PortPilotCore

/// Spec: spec-portpilot-private-coordination.md. Each test name carries its PC id and says which bug it catches.
/// Only the clock and process identity are faked (system boundaries); the registry, sidecar and contract are real.
final class ManagedNotificationTests: XCTestCase, @unchecked Sendable {
    // XCTest autoclosures cannot await; these evaluate first, then assert.
    private func aEqual<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () async throws -> T,
                                      _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(), y = try await b(); XCTAssertEqual(x, y, m(), file: file, line: line)
    }
    private func aNil<T>(_ a: @autoclosure () async throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(); XCTAssertNil(x, m(), file: file, line: line)
    }
    private func aNotNil<T>(_ a: @autoclosure () async throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(); XCTAssertNotNil(x, m(), file: file, line: line)
    }
    private func aTrue(_ a: @autoclosure () async throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(); XCTAssertTrue(x, m(), file: file, line: line)
    }

    // MARK: Fixtures

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed: TimeInterval = 0
        private var offset: TimeInterval = 0
        var time: TimeInterval { lock.withLock { elapsed } }
        var date: Date { lock.withLock { Date(timeIntervalSince1970: 10000 + elapsed + offset) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
        func rollBackWall(_ seconds: TimeInterval) { lock.withLock { offset -= seconds } }
    }

    private struct Env {
        let registry: ManagedRegistry
        let disk: ManagedPersistence
        let root: URL
        let clock: Clock
        let services: [ManagedService]
    }

    private struct Creds {
        let enrollmentId: UUID
        let epoch: Int
        let instance: String
        let notify: (actor: String, token: String)
        let control: (actor: String, token: String)
        let file: URL
    }

    private let secretSentinel = "PRIVATE_SENTINEL_" + "01"

    private var actors: [ManagedActor] {
        [("user", ManagedActor.Scope.user), ("owner", .owner), ("reader", .read), ("coord", .coordinator)].map {
            ManagedActor(id: $0.0, scope: $0.1, credentialHash: ManagedDigest.hash(Data("token-\($0.0)".utf8)))
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func seededService(name: String) -> ManagedService {
        var s = ManagedService(id: UUID(), workspace: ManagedWorkspace(id: UUID(), path: "/fixture/private/project", filesystemIdentity: "fs-\(name)"),
                               name: name, variant: "default", launchFingerprint: "fp")
        s.lifecycle = "running"
        s.claims = [ManagedClaim(id: UUID(), actor: "owner-fixture", active: true, revision: 1)]
        s.incarnations = [ManagedIncarnation(hostId: "host", bootId: "boot", pid: 424242, startTime: Date(timeIntervalSince1970: 1000))]
        s.backendPort = 31337; s.stablePort = 20123
        s.tailnet = ManagedTailnetRoute(selector: "private.invalid:443", endpoint: "https://private.invalid", stablePort: 20123,
                                        fingerprint: "f", verified: true, observedAt: Date(timeIntervalSince1970: 1))
        return s
    }

    private func env(names: [String] = ["alpha", "beta"], mutate: (inout ManagedState) -> Void = { _ in }) throws -> Env {
        let root = try directory()
        let disk = try ManagedPersistence(root: root)
        var state = ManagedState(); state.services = names.map(seededService)
        mutate(&state)
        try disk.commit(state)
        let clock = Clock()
        let registry = ManagedRegistry(persistence: disk, actors: actors, uptime: { clock.time }, now: { clock.date }, identity: { _ in nil })
        return Env(registry: registry, disk: disk, root: root, clock: clock, services: state.services)
    }

    private func call(_ env: Env, _ op: String, actor: String = "user", token: String? = nil, revision: Int? = nil,
                      _ payload: [String: ManagedJSON] = [:], registry: ManagedRegistry? = nil) async -> ManagedResponse {
        await (registry ?? env.registry).handle(ManagedRequest(operation: op, actor: actor, credential: token ?? "token-\(actor)",
                                                               expectedRevision: revision, payload: payload))
    }

    private func propose(_ env: Env, _ service: ManagedService, action: String = "stop") async throws -> UUID {
        let r = await call(env, "operation.propose", revision: 1, ["serviceId": .string(service.id.uuidString), "action": .string(action)])
        XCTAssertNil(r.error)
        return try XCTUnwrap(r.operationId)
    }

    private func enrollPayload(_ services: [ManagedService], destination: String = "Fixture inbox") -> [String: ManagedJSON] {
        ["services": .array(services.map { .string($0.id.uuidString) }), "destination": .string(destination),
         "exportedFields": .array(ManagedNotificationContract.allowedFields.map { .string($0) }), "consent": .bool(true)]
    }

    @discardableResult
    private func enroll(_ env: Env, _ services: [ManagedService], registry: ManagedRegistry? = nil) async throws -> Creds {
        let r = await call(env, "export.enroll", enrollPayload(services), registry: registry)
        XCTAssertNil(r.error)
        guard case .object(let data)? = r.data, let path = data["credentialFile"]?.string else { throw XCTSkip("enroll failed") }
        let url = URL(fileURLWithPath: path)
        let file = try JSONDecoder().decode(ManagedExportCredentialFile.self, from: Data(contentsOf: url))
        return Creds(enrollmentId: UUID(uuidString: file.enrollmentId)!, epoch: file.epoch, instance: "agent-" + UUID().uuidString,
                     notify: (file.notification.actor, file.notification.credential),
                     control: (file.control.actor, file.control.credential), file: url)
    }

    private func list(_ env: Env, _ c: Creds, _ payload: [String: ManagedJSON] = [:], registry: ManagedRegistry? = nil) async -> ManagedResponse {
        await call(env, "notifications.list", actor: c.notify.actor, token: c.notify.token, payload, registry: registry)
    }
    private func poll(_ env: Env, _ c: Creds, instance: String? = nil, registry: ManagedRegistry? = nil) async -> ManagedResponse {
        await call(env, "export.control.poll", actor: c.control.actor, token: c.control.token, ["instance": .string(instance ?? c.instance)], registry: registry)
    }
    private func ack(_ env: Env, _ c: Creds, challenge: String, epoch: Int? = nil, instance: String? = nil,
                     actor: (String, String)? = nil, registry: ManagedRegistry? = nil) async -> ManagedResponse {
        let who = actor ?? (c.control.actor, c.control.token)
        return await call(env, "export.control.ack", actor: who.0, token: who.1,
                          ["instance": .string(instance ?? c.instance), "epoch": .integer(epoch ?? c.epoch), "challenge": .string(challenge)], registry: registry)
    }
    private func disable(_ env: Env, _ c: Creds, registry: ManagedRegistry? = nil) async -> ManagedResponse {
        await call(env, "export.disable", ["enrollmentId": .string(c.enrollmentId.uuidString)], registry: registry)
    }
    private func challenge(_ env: Env, _ c: Creds) async throws -> String {
        let r = await poll(env, c)
        guard case .object(let d)? = r.data, let ch = d["challenge"]?.string else { throw XCTSkip("no challenge") }
        return ch
    }
    /// Disable then acknowledge with the real control credential: the only path to confirmed shutdown.
    private func shutDown(_ env: Env, _ c: Creds) async throws {
        let d = await disable(env, c); XCTAssertNil(d.error)
        let a = await ack(env, c, challenge: try await challenge(env, c)); XCTAssertNil(a.error)
    }

    private func records(_ r: ManagedResponse) throws -> [ManagedNotificationRecord] {
        guard let data = r.data else { throw XCTSkip("no data: \(String(describing: r.error))") }
        return try ManagedNotificationContract.validatePage(JSONEncoder().encode(data)).records
    }
    private func object(_ r: ManagedResponse) -> [String: ManagedJSON] {
        if case .object(let o)? = r.data { return o }; return [:]
    }
    private func enrollments(_ env: Env) async -> [[String: ManagedJSON]] {
        let r = await call(env, "export.status")
        guard case .array(let items)? = object(r)["enrollments"] else { return [] }
        return items.compactMap { if case .object(let o) = $0 { return o }; return nil }
    }
    private func sidecar(_ env: Env) throws -> [String: Any] {
        let data = try XCTUnwrap(try env.disk.read("export-state.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: PC02

    func testPC02FreshRegistryHasNoEnrollmentAndPublicExportCodeHasNoNetworkAPIs() async throws {
        // Bug caught: default-on export, or a network destination compiled into public code.
        let e = try env()
        await aTrue(await enrollments(e).isEmpty)
        await aEqual(object(await call(e, "export.status"))["exportUnavailable"], .bool(false))
        XCTAssertNil(try e.disk.read("export-state.json"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/PortPilotCore/Managed/ManagedExport.swift", "Sources/PortPilot/Views/ManagedExportView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for banned in ["URLSession", "import Network", "NWConnection", "http://", "https://"] {
                XCTAssertFalse(source.contains(banned), "\(path) contains \(banned)")
            }
        }
    }

    // MARK: PC05 / PC12

    func testPC05NotificationCredentialReachesOnlyNotificationsList() async throws {
        // Bug caught: export credential falling through to legacy read/operation handling.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); let op = try await propose(e, s)
        let sid = ManagedJSON.string(s.id.uuidString)
        let probes: [(String, [String: ManagedJSON])] = [
            ("services.list", [:]), ("service.inspect", ["serviceId": sid]), ("operations.list", [:]), ("events.list", [:]),
            ("status", [:]), ("operation.propose", ["serviceId": sid, "action": .string("stop")]),
            ("decision.resolve", ["serviceId": sid, "operationId": .string(op.uuidString), "approved": .bool(true)]),
            ("operation.execute", ["serviceId": sid, "operationId": .string(op.uuidString)]),
            ("claim.acquire", ["serviceId": sid]), ("export.enroll", enrollPayload([s])), ("export.status", [:]),
            ("export.disable", ["enrollmentId": .string(c.enrollmentId.uuidString)]),
            ("export.control.poll", ["instance": .string(c.instance)]),
            ("export.control.ack", ["instance": .string(c.instance), "epoch": .integer(1), "challenge": .string("x")]),
        ]
        for (name, payload) in probes {
            let r = await call(e, name, actor: c.notify.actor, token: c.notify.token, revision: 1, payload)
            XCTAssertEqual(r.error, .unauthorized, name)
        }
        await aNil(await list(e, c).error)
    }

    func testPC12ControlCredentialReachesOnlyControlOperations() async throws {
        // Bug caught: the shutdown-acknowledgement credential also being able to read records or mutate services.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); let op = try await propose(e, s)
        let sid = ManagedJSON.string(s.id.uuidString)
        let probes: [(String, [String: ManagedJSON])] = [
            ("notifications.list", [:]), ("services.list", [:]), ("status", [:]), ("operations.list", [:]),
            ("decision.resolve", ["serviceId": sid, "operationId": .string(op.uuidString), "approved": .bool(true)]),
            ("operation.execute", ["serviceId": sid, "operationId": .string(op.uuidString)]),
            ("claim.acquire", ["serviceId": sid]), ("export.enroll", enrollPayload([s])), ("export.disable", ["enrollmentId": .string(c.enrollmentId.uuidString)]),
        ]
        for (name, payload) in probes {
            let r = await call(e, name, actor: c.control.actor, token: c.control.token, revision: 1, payload)
            XCTAssertEqual(r.error, .unauthorized, name)
        }
        await aNil(await poll(e, c).error)
    }

    func testPC05ExportCredentialsCannotStartServicesThroughSupervisor() async throws {
        // Bug caught: Supervisor.preflight authenticating export actors, allowing launch/adopt/tailnet/execute.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let supervisor = ManagedSupervisor(registry: e.registry, key: Data("k".utf8), persistence: e.disk)
        for (actor, token) in [c.notify, c.control] {
            for op in ["service.run", "service.adopt", "tailnet.enroll", "operation.execute"] {
                let r = await supervisor.handle(ManagedRequest(operation: op, actor: actor, credential: token, expectedRevision: 0,
                                                               payload: ["operationId": .string(UUID().uuidString)]))
                XCTAssertEqual(r.error, .unauthorized, "\(actor) \(op)")
            }
        }
    }

    func testPC05LegacyScopesCannotUseExportOperationsExceptUserAdmin() async throws {
        // Bug caught: legacy read/owner/coordinator actors reading notifications or administering export.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        for actor in ["reader", "owner", "coord"] {
            for (op, payload) in [("notifications.list", [String: ManagedJSON]()), ("export.status", [:]), ("export.enroll", enrollPayload([e.services[0]])),
                                  ("export.disable", ["enrollmentId": .string(c.enrollmentId.uuidString)]),
                                  ("export.control.poll", ["instance": .string(c.instance)])] {
                let r = await call(e, op, actor: actor, payload)
                XCTAssertEqual(r.error, .unauthorized, "\(actor) \(op)")
            }
        }
        let user = await call(e, "notifications.list")
        XCTAssertEqual(user.error, .unauthorized, "user administers export but cannot read the stream")
    }

    // MARK: PC06 / PC07

    func testPC06ExportedBytesContainOnlyAllowlistedFields() async throws {
        // Bug caught: leaking path, name, owner, URL, PID or port through the projection.
        let e = try env(names: [secretSentinel])
        let s = e.services[0]
        let c = try await enroll(e, [s]); _ = try await propose(e, s)
        let r = await list(e, c)
        let bytes = try JSONEncoder().encode(try XCTUnwrap(r.data))
        let text = String(decoding: bytes, as: UTF8.self)
        for leaked in ["/fixture/private/project", "owner-fixture", secretSentinel, "private.invalid", "424242", "31337", "20123", s.id.uuidString, "user"] {
            XCTAssertFalse(text.contains(leaked), leaked)
        }
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let record = try XCTUnwrap((page["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(record.keys), Set(ManagedNotificationContract.allowedFields))
        XCTAssertEqual(record["ownerCount"] as? Int, 1)
        XCTAssertEqual(record["status"] as? String, "pending_decision")
        XCTAssertEqual(page["nextPageToken"] is NSNull, true, "end of stream encodes explicit null")
    }

    func testPC07UnselectedServiceNeverAppears() async throws {
        // Bug caught: exporting every service's decisions instead of only the enrollment's selection.
        let e = try env()
        let a = e.services[0], b = e.services[1]
        let c1 = try await enroll(e, [a])
        _ = try await propose(e, a); _ = try await propose(e, a); _ = try await propose(e, b)
        try await aEqual(try records(await list(e, c1)).count, 2)
        try await aEqual(try records(await list(e, c1, ["after": .integer(0)])).count, 2)
        try await shutDown(e, c1)
        let c2 = try await enroll(e, [b])
        let only = try records(await list(e, c2))
        XCTAssertEqual(only.count, 1, "second enrollment selects only B")
        try await aEqual(try records(await list(e, c2, ["after": .integer(0)])).count, 1)
    }

    // MARK: PC08 / PC16

    func testPC08PC16DisableRevokesImmediatelyReplacementNeedsConfirmedShutdownAndRotatesRefs() async throws {
        // Bug caught: revoked read credential/page token still working; replacement before shutdown; refs reused across epochs.
        let e = try env()
        let s = e.services[0]
        let c1 = try await enroll(e, [s])
        _ = try await propose(e, s); _ = try await propose(e, s)
        let first = await list(e, c1, ["limit": .integer(1)])
        let token = try XCTUnwrap(object(first)["nextPageToken"]?.string)
        let ref1 = try records(first)[0].serviceRef
        await aNil(await disable(e, c1).error)
        await aEqual(await list(e, c1).error, .unauthorized)
        await aEqual(await list(e, c1, ["pageToken": .string(token)]).error, .unauthorized)
        await aEqual(await call(e, "export.enroll", enrollPayload([s])).error, .needsDecision, "unconfirmed shutdown blocks replacement")
        let a = await ack(e, c1, challenge: try await challenge(e, c1)); XCTAssertNil(a.error)
        let c2 = try await enroll(e, [s])
        XCTAssertEqual(c2.epoch, c1.epoch + 1)
        let ref2 = try records(await list(e, c2))[0].serviceRef
        XCTAssertNotEqual(ref1, ref2)
        await aEqual(await list(e, c1).error, .unauthorized)
        await aEqual(await list(e, c1, ["pageToken": .string(token)]).error, .unauthorized)
        await aEqual(await list(e, c2, ["pageToken": .string(token)]).error, .unauthorized, "epoch-1 token is useless to epoch 2")
        await aEqual(await call(e, "export.enroll", enrollPayload([s])).error, .needsDecision, "active enrollment blocks a second one")
    }

    // MARK: PC09

    func testPC09PaginationResyncsWhenDecisionAppearsAfterFirstPage() async throws {
        // Bug caught: a page-2 token silently skipping a decision created while paging.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s])
        for _ in 0..<201 { _ = try await propose(e, s) }
        let p1 = await list(e, c)
        XCTAssertEqual(try records(p1).count, 200)
        let token = try XCTUnwrap(object(p1)["nextPageToken"]?.string)
        let untouched = await list(e, c, ["pageToken": .string(token)])
        XCTAssertEqual(try records(untouched).count, 1)
        XCTAssertEqual(object(untouched)["nextPageToken"], .null)
        XCTAssertEqual(object(untouched)["snapshotId"], object(p1)["snapshotId"])
        _ = try await propose(e, s)
        await aEqual(await list(e, c, ["pageToken": .string(token)]).error, .resyncRequired)
        let fresh = await list(e, c)
        XCTAssertEqual(try records(fresh).count, 200)
        let all = try records(fresh) + records(await list(e, c, ["pageToken": .string(try XCTUnwrap(object(fresh)["nextPageToken"]?.string))]))
        XCTAssertEqual(Set(all.map(\.decisionRef)).count, 202)
    }

    func testPC09ChangesModeReturnsOnlyChangedDecisionsIncludingTerminal() async throws {
        // Bug caught: changes mode re-sending everything, or dropping a decision that just became denied.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s])
        let first = try await propose(e, s)
        let snap = await list(e, c)
        let mark = try XCTUnwrap(object(snap)["highWaterMark"]?.integer)
        _ = try await propose(e, s)
        let denied = await call(e, "decision.resolve", revision: 1, ["serviceId": .string(s.id.uuidString), "operationId": .string(first.uuidString), "approved": .bool(false)])
        XCTAssertNil(denied.error)
        let changes = try records(await list(e, c, ["after": .integer(mark)]))
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.filter { $0.status == .denied }.count, 1)
        XCTAssertEqual(changes.filter { $0.status == .pendingDecision }.count, 1)
        try await aEqual(try records(await list(e, c)).map(\.status), [.pendingDecision], "snapshot lists only non-terminal decisions")
        let latest = await list(e, c)
        let latestMark = try XCTUnwrap(object(latest)["highWaterMark"]?.integer)
        let none = try records(await list(e, c, ["after": .integer(latestMark)]))
        XCTAssertTrue(none.isEmpty)
    }

    func testPC09CursorOlderThanRetainedEventsRequiresResync() async throws {
        // Bug caught: serving a gapped change stream after events expired.
        let e = try env { $0.lastEventSequence = 10 }
        let c = try await enroll(e, [e.services[0]])
        await aEqual(await list(e, c, ["after": .integer(3)]).error, .resyncRequired)
        await aEqual(await list(e, c, ["after": .integer(11)]).error, .resyncRequired, "cursor ahead of the helper is also invalid")
        await aNil(await list(e, c, ["after": .integer(10)]).error)
        let snap = await list(e, c)
        XCTAssertEqual(object(snap)["highWaterMark"], .integer(10), "bootstrap works with no retained events")
    }

    func testPC09BootstrapIncludesOpenDecisionWhoseEventsAreGone() async throws {
        // Bug caught: bootstrap derived from the event log, losing open decisions after their events expire.
        var seeded: ManagedOperation?
        let e = try env { state in
            let s = state.services[0]
            let op = ManagedOperation(id: UUID(), serviceId: s.id, action: "reroute", revision: s.revision, targets: s.incarnations,
                                      generation: 0, actor: "coord", phase: "needs_review", outcome: "preparation_failed_port",
                                      expires: Date(timeIntervalSince1970: 0))
            state.operations = [op]; state.events = []; state.lastEventSequence = 40
            seeded = op
        }
        let c = try await enroll(e, [e.services[0]])
        let page = await list(e, c)
        let got = try records(page)
        XCTAssertEqual(got.count, 1, "operation is reported although no event references it")
        XCTAssertEqual(got.first?.status, .needsReview)
        XCTAssertEqual(got.first?.outcome, .failed)
        XCTAssertEqual(object(page)["highWaterMark"], .integer(40))
        XCTAssertNotNil(seeded)
    }

    func testPC09HelperRestartInvalidatesPageToken() async throws {
        // Bug caught: a token surviving a helper restart and resuming a stale snapshot.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s])
        _ = try await propose(e, s); _ = try await propose(e, s)
        let firstPage = await list(e, c, ["limit": .integer(1)])
        let token = try XCTUnwrap(object(firstPage)["nextPageToken"]?.string)
        let restarted = ManagedRegistry(persistence: e.disk, actors: actors, uptime: { e.clock.time }, now: { e.clock.date }, identity: { _ in nil })
        await aEqual(await list(e, c, ["pageToken": .string(token)], registry: restarted).error, .resyncRequired)
    }

    func testPC09PageTokenIsAuthenticatedAndBoundToActor() async throws {
        // Bug caught: forged or edited tokens (offset/mode) accepted; token usable by another actor.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s])
        _ = try await propose(e, s); _ = try await propose(e, s)
        let firstPage = await list(e, c, ["limit": .integer(1)])
        let token = try XCTUnwrap(object(firstPage)["nextPageToken"]?.string)
        await aEqual(await list(e, c, ["pageToken": .string("garbage")]).error, .invalidInput)
        await aEqual(await list(e, c, ["pageToken": .string(String(token.dropLast()) + (token.hasSuffix("0") ? "1" : "0"))]).error, .unauthorized)
        await aEqual(await list(e, c, ["pageToken": .string(token), "after": .integer(0)]).error, .invalidInput)
    }

    func testPC09StrictRequestValidation() async throws {
        // Bug caught: lenient parsing (string limit, unknown keys, out-of-range limits) widening the contract.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        _ = try await propose(e, e.services[0]); _ = try await propose(e, e.services[0])
        await aEqual(await list(e, c, ["limit": .string("5")]).error, .invalidInput)
        await aEqual(await list(e, c, ["limit": .integer(0)]).error, .invalidInput)
        await aEqual(await list(e, c, ["limit": .integer(201)]).error, .invalidInput)
        await aEqual(await list(e, c, ["extra": .bool(true)]).error, .invalidInput)
        await aEqual(await list(e, c, ["after": .string("1")]).error, .invalidInput)
        try await aEqual(try records(await list(e, c, ["limit": .integer(1)])).count, 1)
        try await aEqual(try records(await list(e, c, ["limit": .integer(200)])).count, 2)
    }

    func testStrictWireRejectsDuplicateKeyInNotificationsListBody() throws {
        // Bug caught: a duplicate `limit`/`after` key letting parser choice decide what the helper reads.
        let body = #"{"protocolVersion":1,"requestId":"r","operation":"notifications.list","actor":"a","credential":"c","payload":{"limit":1,"limit":200}}"#
        XCTAssertThrowsError(try ManagedWire.decode(Data(body.utf8))) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
        let escaped = #"{"protocolVersion":1,"requestId":"r","operation":"notifications.list","actor":"a","credential":"c","payload":{"limit":1,"limit":200}}"#
        XCTAssertThrowsError(try ManagedWire.decode(Data(escaped.utf8)))
    }

    // MARK: PC10

    func testPC10RepeatedListingOfUnchangedDecisionIsStable() async throws {
        // Bug caught: refs or snapshot ids that change with time, producing duplicate logical notifications.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); _ = try await propose(e, s)
        let one = await list(e, c)
        e.clock.advance(20)
        let two = await list(e, c)
        XCTAssertEqual(try records(one).first?.decisionRef, try records(two).first?.decisionRef)
        XCTAssertEqual(object(one)["snapshotId"], object(two)["snapshotId"])
        XCTAssertNotEqual(try records(one).first?.observedAt, try records(two).first?.observedAt)
    }

    func testPC10WallClockRollbackAndExpiryNeverRevivePendingDecision() async throws {
        // Bug caught: an expired or rolled-back decision reappearing as pending_decision.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); _ = try await propose(e, s)
        try await aEqual(try records(await list(e, c)).first?.status, .pendingDecision)
        e.clock.rollBackWall(3600)
        try await aTrue(try records(await list(e, c)).isEmpty, "rolled-back clock must not revive the decision in the pending set")
        try await aEqual(try records(await list(e, c, ["after": .integer(0)])).first?.status, .expired)
        let fresh = try env()
        let c2 = try await enroll(fresh, [fresh.services[0]]); _ = try await propose(fresh, fresh.services[0])
        fresh.clock.advance(601)
        try await aEqual(try records(await list(fresh, c2, ["after": .integer(0)])).first?.status, .expired)
    }

    func testPC10ChangedServiceRevisionWithdrawsDecision() async throws {
        // Bug caught: an ownership/target change leaving a stale decision looking approvable.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); _ = try await propose(e, s)
        // The service revision moves on (claims, route or target changes do this); the decision no longer matches.
        var moved = s; moved.revision += 1
        let operation = try XCTUnwrap(try e.disk.load().operations.first)
        let at = e.clock.date
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: operation, service: s, now: at, uptime: 0, deadline: 100), .pendingDecision)
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: operation, service: moved, now: at, uptime: 0, deadline: 100), .withdrawn)
        var retargeted = s; retargeted.incarnations = []
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: operation, service: retargeted, now: at, uptime: 0, deadline: 100), .withdrawn)
        var rerouted = s; rerouted.routeGeneration += 1
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: operation, service: rerouted, now: at, uptime: 0, deadline: 100), .withdrawn)
        // End to end: a persisted revision bump seen by a restarted helper is withdrawn (and expired, since restart loses deadlines).
        var state = try e.disk.load(); state.services[0].revision += 1; try e.disk.commit(state)
        let restarted = ManagedRegistry(persistence: e.disk, actors: actors, uptime: { e.clock.time }, now: { e.clock.date }, identity: { _ in nil })
        try await aTrue(try records(await list(e, c, registry: restarted)).isEmpty)
    }

    func testPC10StatusAndOutcomeMappingNeverExportsRawStrings() throws {
        // Bug caught: unmapped phases or free-form outcomes leaking through, or terminal states misreported.
        func op(_ phase: String, _ outcome: String? = nil) -> ManagedOperation {
            ManagedOperation(id: UUID(), serviceId: UUID(), action: "stop", revision: 1, targets: [], generation: 0, actor: "x",
                             phase: phase, outcome: outcome, expires: Date(timeIntervalSince1970: 100))
        }
        let now = Date(timeIntervalSince1970: 50)
        for phase in ["fenced", "signal_sent", "preparing", "ready", "switched", "observing", "retiring_old", "rolling_back"] {
            XCTAssertEqual(ManagedRegistry.notificationStatus(of: op(phase), service: nil, now: now, uptime: 0, deadline: nil), .executing, phase)
        }
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: op("completed"), service: nil, now: now, uptime: 0, deadline: nil), .completed)
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: op("denied"), service: nil, now: now, uptime: 0, deadline: nil), .denied)
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: op("needs_review"), service: nil, now: now, uptime: 0, deadline: nil), .needsReview)
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: op("something_new"), service: nil, now: now, uptime: 0, deadline: nil), .needsReview)
        XCTAssertEqual(ManagedRegistry.notificationStatus(of: op("proposed"), service: nil, now: now, uptime: 0, deadline: nil), .expired, "missing deadline means expired")
        let pairs: [(String?, ManagedNotificationOutcome)] = [
            (nil, .none), ("exit_verified", .verified), ("route_verified_old_exit_verified", .verified),
            ("exit_not_yet_verified", .unverified), ("rolled_back_replacement_retained_for_review", .unverified),
            ("old_tree_exit_unverified", .unverified), ("identity_or_signal_failed", .failed), ("no_healthy_backend", .failed),
            ("preparation_failed_port", .failed), ("/Users/someone/secret", .unverified),
        ]
        for (raw, expected) in pairs { XCTAssertEqual(ManagedRegistry.notificationOutcome(raw), expected, raw ?? "nil") }
    }

    // MARK: PC11

    func testPC11ListAndDisableLeaveRegistryBytesAndClaimsUnchanged() async throws {
        // Bug caught: export traffic bumping the registry revision, committing registry.json or touching claims/operations.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); _ = try await propose(e, s)
        let before = try XCTUnwrap(try e.disk.read("registry.json"))
        let claims = await e.registry.snapshot().map(\.claims.count)
        _ = await list(e, c); _ = await poll(e, c); _ = await call(e, "export.status")
        await aNil(await disable(e, c).error)
        try await aNil(await ack(e, c, challenge: try await challenge(e, c)).error)
        XCTAssertEqual(try e.disk.read("registry.json"), before)
        await aEqual(await e.registry.snapshot().map(\.claims.count), claims)
        await aEqual(await e.registry.snapshot().map(\.revision), [1, 1])
    }

    // MARK: PC13

    private func validRecordJSON() throws -> [String: Any] {
        let record = ManagedNotificationRecord(serviceRef: "svc_" + String(repeating: "a", count: 32), decisionRef: "dec_" + String(repeating: "b", count: 32),
            serviceRevision: 1, action: .stop, status: .pendingDecision, outcome: .none, routeGeneration: 0, ownerCount: 1, observedAt: 1, expiresAt: 2)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }
    private func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    func testPC13ContractRejectsMalformedRecords() throws {
        // Bug caught: a lenient receiver accepting wrong types, unknown schema, unknown fields or duplicate keys.
        let valid = try validRecordJSON()
        XCTAssertNoThrow(try ManagedNotificationContract.validateRecord(bytes(valid)))
        func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data { var v = valid; change(&v); return try bytes(v) }
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(mutated { $0["schemaVersion"] = 99 })) { XCTAssertEqual($0 as? ManagedError, .protocolMismatch) }
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(mutated { $0["serviceRevision"] = "1" })) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(mutated { $0["path"] = "/x" })) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(mutated { $0.removeValue(forKey: "expiresAt") }))
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(mutated { $0["status"] = "approved" }))
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(mutated { $0["serviceRef"] = "svc_/Us" + "ers/me" }))
        let duplicate = String(decoding: try bytes(valid), as: UTF8.self).replacingOccurrences(of: "\"action\":\"stop\"", with: "\"action\":\"stop\",\"action\":\"force\"")
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(Data(duplicate.utf8))) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(Data([0x7b, 0xff, 0x7d]))) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
    }

    func testPC13RecordSizeBoundary() throws {
        // Bug caught: off-by-one on the 8 KiB record limit.
        let base = try bytes(try validRecordJSON())
        let atLimit = base + Data(repeating: 0x20, count: ManagedNotificationContract.maxRecordBytes - base.count)
        XCTAssertEqual(atLimit.count, 8192)
        XCTAssertNoThrow(try ManagedNotificationContract.validateRecord(atLimit))
        XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(atLimit + Data([0x20]))) { XCTAssertEqual($0 as? ManagedError, .recordTooLarge) }
    }

    func testPC13PageBoundaries() throws {
        // Bug caught: accepting 201 records or an oversized page.
        let record = try validRecordJSON()
        func page(_ count: Int, schema: Int = 1) throws -> Data {
            try bytes(["schemaVersion": schema, "enrollmentEpoch": 1, "snapshotId": "abc", "highWaterMark": 0, "helperInstance": "h",
                       "records": Array(repeating: record, count: count), "nextPageToken": NSNull()])
        }
        XCTAssertEqual(try ManagedNotificationContract.validatePage(page(200)).records.count, 200)
        XCTAssertEqual(try ManagedNotificationContract.validatePage(page(0)).records.count, 0)
        XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page(201))) { XCTAssertEqual($0 as? ManagedError, .recordTooLarge) }
        XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page(1, schema: 99))) { XCTAssertEqual($0 as? ManagedError, .protocolMismatch) }
        XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page(1) + Data(repeating: 0x20, count: ManagedNotificationContract.maxPageBytes)))
    }

    func testPC13ClientDisablesDeliveryOnUnsupportedSchemaWithoutCredentialFallback() async throws {
        // Bug caught: retrying with a second credential, or continuing to poll, after a schema mismatch.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        final class Seen: @unchecked Sendable { let lock = NSLock(); var actors: [String] = []; func add(_ a: String) { lock.withLock { actors.append(a) } } }
        let seen = Seen()
        let future = ManagedResponse(requestId: nil, data: .object(["schemaVersion": .integer(99), "records": .array([])]))
        let client = ManagedNotificationClient(root: e.root, credentialFile: c.file, transport: { seen.add($0.actor); return future })
        XCTAssertThrowsError(try client.list()) { XCTAssertEqual($0 as? ManagedError, .protocolMismatch) }
        XCTAssertTrue(client.deliveryDisabled)
        XCTAssertThrowsError(try client.list())
        XCTAssertEqual(seen.actors, [c.notify.actor], "one request, notification credential only, no retry")
    }

    func testPC13ClientValidatesRealRegistryPage() async throws {
        // Bug caught: client returning unvalidated pages or reading a credential file it should not.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s]); _ = try await propose(e, s)
        let real = await list(e, c)
        let client = ManagedNotificationClient(root: e.root, credentialFile: c.file, transport: { _ in real })
        XCTAssertEqual(try client.list().records.count, 1)
        XCTAssertFalse(client.deliveryDisabled)
        let wrong = e.root.appendingPathComponent("gui-credential.json")
        try Data("{}".utf8).write(to: wrong)
        XCTAssertThrowsError(try ManagedNotificationClient(root: e.root, credentialFile: wrong, transport: { _ in real }).list(), "world-readable credential file refused")
    }

    // MARK: PC14

    func testPC14LocalManagementSurvivesAgentRemoval() async throws {
        // Bug caught: local management coupled to the presence of the private agent/credentials.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s])
        await aNil(await disable(e, c).error)
        await aNil(await call(e, "export.remove_agent", ["enrollmentId": .string(c.enrollmentId.uuidString)]).error)
        try? FileManager.default.removeItem(at: c.file)
        await aNil(await call(e, "services.list").error)
        await aNil(await call(e, "operations.list").error)
        try await aNotNil(try await propose(e, s))
        await aEqual(await e.registry.snapshot()[0].activeClaims.count, 1)
    }

    // MARK: PC16 / PC17

    func testPC17WrongChallengeEpochOrInstanceCannotConfirmShutdown() async throws {
        // Bug caught: any acknowledgement (stale instance, wrong epoch, guessed challenge) completing the fence.
        let e = try env()
        let s = e.services[0]
        let old = try await enroll(e, [s]); try await shutDown(e, old)
        let c = try await enroll(e, [s])
        await aNil(await poll(e, c).error)   // registers this process
        await aEqual(await ack(e, c, challenge: "anything").error, .staleRevision, "no challenge exists while active")
        await aNil(await disable(e, c).error)
        let good = try await challenge(e, c)
        await aEqual(await ack(e, c, challenge: "wrong").error, .staleRevision)
        await aEqual(await ack(e, c, challenge: good, epoch: c.epoch - 1).error, .unauthorized)
        await aEqual(await ack(e, c, challenge: good, instance: old.instance).error, .unauthorized)
        await aEqual(await ack(e, old, challenge: good).error, .unauthorized, "previous enrollment's control credential is retired")
        await aEqual(await ack(e, c, challenge: good, actor: c.notify).error, .unauthorized, "read credential cannot acknowledge")
        let state = await enrollments(e)
        XCTAssertEqual(state.last?["shutdownConfirmed"], .bool(false))
        XCTAssertEqual(state.last?["display"], .string("revoked_shutdown_unconfirmed"))
    }

    func testPC17MatchingAckConfirmsIsIdempotentAndCannotReactivate() async throws {
        // Bug caught: ack not durable before reply, retry failing after commit, or ack reviving export.
        let e = try env()
        let s = e.services[0]
        let c = try await enroll(e, [s])
        await aNil(await disable(e, c).error)
        await aNil(await disable(e, c).error, "disable is idempotent")
        let before = try await challenge(e, c)
        try await aEqual(try await challenge(e, c), before, "poll does not rotate the challenge")
        await aNil(await ack(e, c, challenge: before).error)
        let persisted = try sidecar(e)
        XCTAssertEqual(((persisted["enrollments"] as? [[String: Any]])?.first?["state"]) as? String, "acknowledged", "durable before the reply returned")
        let generation = persisted["generation"] as? Int
        await aNil(await ack(e, c, challenge: before).error, "identical retry after commit succeeds")
        XCTAssertEqual(try sidecar(e)["generation"] as? Int, generation, "retry does not rewrite")
        await aEqual(await list(e, c).error, .unauthorized)
        let polled = object(await poll(e, c))
        XCTAssertEqual(polled["acknowledged"], .bool(true))
        XCTAssertEqual(polled["state"], .string("acknowledged"))
        await aEqual(await enrollments(e).last?["display"], .string("disabled_shutdown_confirmed"))
    }

    func testPC17PollWorksAfterReadRevocationAndRequiresMatchingInstance() async throws {
        // Bug caught: control channel dying with the read credential, or accepting a foreign instance id.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let active = object(await poll(e, c))
        XCTAssertEqual(active["state"], .string("active")); XCTAssertNil(active["challenge"])
        XCTAssertEqual(active["protocolVersion"], .integer(1)); XCTAssertEqual(active["notificationSchema"], .integer(1))
        await aNil(await disable(e, c).error)
        await aNotNil(object(await poll(e, c))["challenge"]?.string)
        await aEqual(await poll(e, c, instance: UUID().uuidString).error, .unauthorized)
    }

    func testPC17RemoveAgentRetiresCredentialsButDoesNotConfirmShutdown() async throws {
        // Bug caught: removing the agent being treated as confirmation (spec: removal alone is not shutdown).
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        await aEqual(await call(e, "export.remove_agent", ["enrollmentId": .string(c.enrollmentId.uuidString)]).error, .needsDecision, "active enrollment must be disabled first")
        await aNil(await disable(e, c).error)
        await aNil(await call(e, "export.remove_agent", ["enrollmentId": .string(c.enrollmentId.uuidString)]).error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.file.path))
        await aEqual(await poll(e, c).error, .unauthorized)
        let status = await enrollments(e)
        XCTAssertEqual(status.last?["shutdownConfirmed"], .bool(false))
        XCTAssertEqual(status.last?["state"], .string("revoked"))
        await aEqual(await call(e, "export.enroll", enrollPayload([e.services[0]])).error, .needsDecision, "still blocked: shutdown unconfirmed")
    }

    func testPC16ExplicitAbandonPermitsReplacementWithoutClaimingConfirmation() async throws {
        // Bug caught: abandon either blocking recovery forever or falsely reporting confirmed shutdown.
        let e = try env()
        let c1 = try await enroll(e, [e.services[0]])
        await aEqual(await call(e, "export.abandon", ["enrollmentId": .string(c1.enrollmentId.uuidString), "acknowledgeUnconfirmed": .bool(true)]).error, .needsDecision, "only from revoked")
        await aNil(await disable(e, c1).error)
        await aEqual(await call(e, "export.abandon", ["enrollmentId": .string(c1.enrollmentId.uuidString)]).error, .invalidInput, "explicit acknowledgement required")
        await aNil(await call(e, "export.abandon", ["enrollmentId": .string(c1.enrollmentId.uuidString), "acknowledgeUnconfirmed": .bool(true)]).error)
        let status = await enrollments(e).last
        XCTAssertEqual(status?["display"], .string("abandoned_shutdown_unconfirmed"))
        XCTAssertEqual(status?["shutdownConfirmed"], .bool(false))
        await aEqual(await poll(e, c1).error, .unauthorized)
        let c2 = try await enroll(e, [e.services[1]])
        XCTAssertEqual(c2.epoch, 2)
        XCTAssertEqual(try sidecar(e)["epochHighWater"] as? Int, 2)
    }

    func testPC16EnrollmentConsentValidationIsStrict() async throws {
        // Bug caught: enrolling without consent, with unknown services, hidden fields or control characters in the destination.
        let e = try env()
        var p = enrollPayload([e.services[0]])
        func attempt(_ edit: (inout [String: ManagedJSON]) -> Void) async -> ManagedError? { var q = p; edit(&q); return await call(e, "export.enroll", q).error }
        await aEqual(await attempt { $0["consent"] = .bool(false) }, .invalidInput)
        await aEqual(await attempt { $0.removeValue(forKey: "consent") }, .invalidInput)
        await aEqual(await attempt { $0["consent"] = .string("true") }, .invalidInput)
        await aEqual(await attempt { $0["unexpected"] = .bool(true) }, .invalidInput)
        await aEqual(await attempt { $0["services"] = .array([]) }, .invalidInput)
        await aEqual(await attempt { $0["services"] = .array([.string(UUID().uuidString)]) }, .invalidInput)
        await aEqual(await attempt { $0["services"] = .array([.string(e.services[0].id.uuidString), .string(e.services[0].id.uuidString)]) }, .invalidInput)
        await aEqual(await attempt { $0["destination"] = .string("") }, .invalidInput)
        await aEqual(await attempt { $0["destination"] = .string("bad\nname") }, .invalidInput)
        await aEqual(await attempt { $0["destination"] = .string(String(repeating: "x", count: 81)) }, .invalidInput)
        await aEqual(await attempt { $0["exportedFields"] = .array(ManagedNotificationContract.allowedFields.dropLast().map { .string($0) }) }, .invalidInput)
        await aEqual(await attempt { $0["exportedFields"] = .array((ManagedNotificationContract.allowedFields + ["path"]).map { .string($0) }) }, .invalidInput)
        await aTrue(await enrollments(e).isEmpty, "no rejected attempt left state behind")
        p["destination"] = .string(String(repeating: "x", count: 80))
        await aNil(await call(e, "export.enroll", p).error)
    }

    func testPC16EnrollResponseNeverContainsRawTokensAndCredentialFileIsPrivate() async throws {
        // Bug caught: bearer tokens echoed in responses, or the credential file readable by other users.
        let e = try env()
        let r = await call(e, "export.enroll", enrollPayload([e.services[0]]))
        XCTAssertNil(r.error)
        let path = try XCTUnwrap(object(r)["credentialFile"]?.string)
        let file = try JSONDecoder().decode(ManagedExportCredentialFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let response = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(response.contains(file.notification.credential))
        XCTAssertFalse(response.contains(file.control.credential))
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let sidecarText = String(decoding: try XCTUnwrap(try e.disk.read("export-state.json")), as: UTF8.self)
        XCTAssertFalse(sidecarText.contains(file.notification.credential), "only hashes are stored")
        XCTAssertTrue(file.notification.actor.hasPrefix("export-notify-") && file.control.actor.hasPrefix("export-control-"))
    }

    // MARK: PC18

    func testPC18LegacyActorsFormatDecodesAndEnrollmentLeavesActorsFileUntouched() async throws {
        // Bug caught: export enrollment rewriting/extending actors.json, which an older helper must still decode.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/fixtures/managed-actors-legacy.json")
        let bytes = try Data(contentsOf: fixture)
        let legacy = try JSONDecoder().decode([ManagedActor].self, from: bytes)
        XCTAssertEqual(legacy.map(\.scope), [.user, .read, .owner, .coordinator])
        let root = try directory(); let disk = try ManagedPersistence(root: root)
        try disk.write("actors.json", data: bytes)
        var state = ManagedState(); state.services = [seededService(name: "alpha")]; try disk.commit(state)
        let registry = ManagedRegistry(persistence: disk, actors: legacy)
        let env = Env(registry: registry, disk: disk, root: root, clock: Clock(), services: state.services)
        let r = await registry.handle(ManagedRequest(operation: "export.enroll", actor: "fixture-user", credential: "legacy-token-fixture-user", payload: enrollPayload(state.services)))
        XCTAssertNil(r.error)
        XCTAssertEqual(try disk.read("actors.json"), bytes)
        XCTAssertEqual(try JSONDecoder().decode([ManagedActor].self, from: try XCTUnwrap(disk.read("actors.json"))), legacy)
        await aNil(await call(env, "services.list", actor: "fixture-reader", token: "legacy-token-fixture-reader", registry: registry).error)
        let sidecarText = String(decoding: try XCTUnwrap(try disk.read("actors.json")), as: UTF8.self)
        XCTAssertFalse(sidecarText.contains("notification_read") || sidecarText.contains("export_control"))
    }

    func testPC18UnknownSidecarSchemaFailsExportClosedWithoutTouchingLocalManagementOrFile() async throws {
        // Bug caught: a newer sidecar being overwritten/reset by an older helper, or breaking legacy operations.
        let root = try directory(); let disk = try ManagedPersistence(root: root)
        let future = Data(#"{"schema":2,"generation":9,"epochHighWater":4,"payload":"future-format"}"#.utf8)
        try disk.write("export-state.json", data: future)
        var state = ManagedState(); state.services = [seededService(name: "alpha")]; try disk.commit(state)
        let registry = ManagedRegistry(persistence: disk, actors: actors, identity: { _ in nil })
        let e = Env(registry: registry, disk: disk, root: root, clock: Clock(), services: state.services)
        await aEqual(await call(e, "export.enroll", enrollPayload(state.services)).error, .protocolMismatch)
        await aEqual(await call(e, "export.status").error, .protocolMismatch)
        await aEqual(await call(e, "notifications.list", actor: "export-notify-x", token: "t").error, .unauthorized)
        await aNil(await call(e, "services.list").error)
        try await aNotNil(try await propose(e, state.services[0]), "legacy mutation still works")
        XCTAssertEqual(try disk.read("export-state.json"), future)
    }

    func testPC18CorruptSidecarFailsExportClosedOnly() async throws {
        // Bug caught: corrupt optional state taking the whole helper into recovery_required.
        let root = try directory(); let disk = try ManagedPersistence(root: root)
        try disk.write("export-state.json", data: Data("not json".utf8))
        var state = ManagedState(); state.services = [seededService(name: "alpha")]; try disk.commit(state)
        let registry = ManagedRegistry(persistence: disk, actors: actors, identity: { _ in nil })
        let e = Env(registry: registry, disk: disk, root: root, clock: Clock(), services: state.services)
        await aEqual(await call(e, "export.enroll", enrollPayload(state.services)).error, .recoveryRequired)
        await aNil(await call(e, "services.list").error)
        try await aNotNil(try await propose(e, state.services[0]), "legacy mutation still works")
        XCTAssertEqual(try disk.read("export-state.json"), Data("not json".utf8))
    }

    func testPC18EpochNeverDecreasesAndRevokedStateSurvivesRestart() async throws {
        // Bug caught: restart or re-enrollment reviving revoked authority or reusing an epoch.
        let e = try env()
        let s = e.services[0]
        var marks: [Int] = []
        let c1 = try await enroll(e, [s]); marks.append(try sidecar(e)["epochHighWater"] as! Int)
        let disabled = await disable(e, c1); XCTAssertNil(disabled.error); marks.append(try sidecar(e)["epochHighWater"] as! Int)
        let restarted = ManagedRegistry(persistence: e.disk, actors: actors, uptime: { e.clock.time }, now: { e.clock.date }, identity: { _ in nil })
        await aEqual(await list(e, c1, registry: restarted).error, .unauthorized, "revocation survives restart")
        await aEqual(object(await poll(e, c1, registry: restarted))["state"], .string("revoked"))
        let ch = object(await poll(e, c1, registry: restarted))["challenge"]?.string ?? ""
        await aNil(await ack(e, c1, challenge: ch, registry: restarted).error)
        marks.append(try sidecar(e)["epochHighWater"] as! Int)
        let c2 = try await enroll(e, [s], registry: restarted); marks.append(try sidecar(e)["epochHighWater"] as! Int)
        XCTAssertEqual(marks, [1, 1, 1, 2])
        XCTAssertEqual(c2.epoch, 2)
        XCTAssertEqual(try sidecar(e)["schema"] as? Int, 1)
        XCTAssertGreaterThan(try sidecar(e)["generation"] as? Int ?? 0, 3, "generation increases on every write")
    }

    func testPC18FailedSidecarWriteDoesNotCreateAnEnrollmentButDisableStillRevokes() async throws {
        // Bug caught: a failed durable write leaving read authority alive after the user asked to disable.
        let root = try directory()
        final class Fault: @unchecked Sendable { let lock = NSLock(); var on = false
            var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } } }
        let fault = Fault()
        let disk = try ManagedPersistence(root: root, writeFault: { name in fault.value && name == "export-state.json" })
        var state = ManagedState(); state.services = [seededService(name: "alpha")]; try disk.commit(state)
        let clock = Clock()
        let registry = ManagedRegistry(persistence: disk, actors: actors, uptime: { clock.time }, now: { clock.date }, identity: { _ in nil })
        let e = Env(registry: registry, disk: disk, root: root, clock: clock, services: state.services)
        let c = try await enroll(e, state.services)
        fault.value = true
        await aEqual(await disable(e, c).error, .recoveryRequired)
        await aEqual(await list(e, c).error, .recoveryRequired, "fail closed: revoked in memory, export blocked until the revocation is durable")
        await aEqual(await call(e, "export.enroll", enrollPayload(state.services)).error, .recoveryRequired)
        fault.value = false
        await aEqual(await list(e, c).error, .unauthorized)
        await aEqual(await call(e, "export.enroll", enrollPayload(state.services)).error, .needsDecision)
        await aNil(await call(e, "services.list").error)
    }

    // MARK: Review fixes: revocation fence, instance binding, storage

    private final class Fault: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
    }
    private func faultyEnv(_ fault: Fault) throws -> Env {
        let root = try directory()
        let disk = try ManagedPersistence(root: root, writeFault: { name in fault.value && name == "export-state.json" })
        var state = ManagedState(); state.services = [seededService(name: "alpha")]; try disk.commit(state)
        let clock = Clock()
        let registry = ManagedRegistry(persistence: disk, actors: actors, uptime: { clock.time }, now: { clock.date }, identity: { _ in nil })
        return Env(registry: registry, disk: disk, root: root, clock: clock, services: state.services)
    }
    private func restart(_ e: Env) -> ManagedRegistry {
        ManagedRegistry(persistence: e.disk, actors: actors, uptime: { e.clock.time }, now: { e.clock.date }, identity: { _ in nil })
    }

    func testDisableWriteFailureDoesNotReviveReadCredentialAfterHelperRestart() async throws {
        // Bug caught: revocation held only in memory, so a restart reloads "active" and the old token works again.
        let fault = Fault(); let e = try faultyEnv(fault)
        let c = try await enroll(e, e.services)
        fault.value = true
        await aEqual(await disable(e, c).error, .recoveryRequired)
        let restarted = restart(e)
        await aEqual(await list(e, c, registry: restarted).error, .recoveryRequired, "revoked via tombstone; export fails closed while the sidecar write is still failing")
        fault.value = false
        await aEqual(await list(e, c, registry: restarted).error, .unauthorized, "once writes recover the revocation is durable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.file.path), "credential file deleted best-effort")
    }

    func testPendingRevocationFailsExportOpsUntilWritesRecoverThenPersists() async throws {
        // Bug caught: serving export requests while the revocation is still undurable, or never retrying the write.
        let fault = Fault(); let e = try faultyEnv(fault)
        let c = try await enroll(e, e.services)
        fault.value = true
        _ = await disable(e, c)
        await aEqual(await call(e, "export.status").error, .recoveryRequired)
        await aEqual(await poll(e, c).error, .recoveryRequired)
        fault.value = false
        await aNil(await call(e, "export.status").error)
        let book = try sidecar(e)
        XCTAssertEqual(((book["enrollments"] as? [[String: Any]])?.first?["state"]) as? String, "revoked")
        XCTAssertTrue(e.disk.names(withPrefix: "export-revoked-").isEmpty, "tombstone cleaned once sidecar is durable")
        await aEqual(await list(e, c, registry: restart(e)).error, .unauthorized)
    }

    func testMissingSidecarWithCredentialOrTombstoneFilesFailsExportClosed() async throws {
        // Bug caught: a lost sidecar resetting epochHighWater to 0 so epochs and revocations are forgotten.
        let e = try env()
        _ = try await enroll(e, [e.services[0]])
        try FileManager.default.removeItem(at: e.root.appendingPathComponent("export-state.json"))
        let r = restart(e)
        await aEqual(await call(e, "export.enroll", enrollPayload([e.services[0]]), registry: r).error, .recoveryRequired)
        await aEqual(await call(e, "export.status", registry: r).error, .recoveryRequired)
        let e2 = try env()
        try e2.disk.write("export-revoked-\(UUID().uuidString.lowercased())", data: Data("{}".utf8))
        await aEqual(await call(e2, "export.status", registry: restart(e2)).error, .recoveryRequired)
        let fresh = try env()
        await aNil(await call(fresh, "export.status").error, "no files at all is still a clean first run")
    }

    func testEnrollRefusedWhileLifecycleLockHeldByHelperReplacement() async throws {
        // Bug caught: enrolling after the replacement's compatibility check, creating state it never saw.
        let e = try env()
        var lock: ManagedLifecycleLock? = try ManagedLifecycleLock(root: e.root)
        await aEqual(await call(e, "export.enroll", enrollPayload([e.services[0]])).error, .operationInProgress)
        lock = nil
        await aNil(await call(e, "export.enroll", enrollPayload([e.services[0]])).error)
        _ = lock
    }

    func testStaleAgentInstanceCannotAcknowledgeAfterRevocation() async throws {
        // Bug caught: a second agent process from the same credential file acknowledging while the first still holds a queue.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let a = "instance-A-0123456789", b = "instance-B-0123456789"
        await aNil(await poll(e, c, instance: a).error)
        await aNil(await disable(e, c).error)
        await aEqual(await poll(e, c, instance: b).error, .unauthorized)
        let challenge = object(await poll(e, c, instance: a))["challenge"]?.string ?? ""
        await aEqual(await ack(e, c, challenge: challenge, instance: b).error, .unauthorized)
        let before = await enrollments(e).last?["shutdownConfirmed"]
        XCTAssertEqual(before, .bool(false))
        await aNil(await ack(e, c, challenge: challenge, instance: a).error)
        let after = await enrollments(e).last?["shutdownConfirmed"]
        XCTAssertEqual(after, .bool(true))
    }

    func testRestartedAgentTakesOverWhileActiveAndOnlyNewInstanceCanAck() async throws {
        // Bug caught: the first process keeping ack authority after a restart replaced it.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let a = "instance-A-0123456789", b = "instance-B-0123456789"
        await aNil(await poll(e, c, instance: a).error)
        await aNil(await poll(e, c, instance: b).error)
        await aNil(await disable(e, c).error)
        let challenge = object(await poll(e, c, instance: b))["challenge"]?.string ?? ""
        await aEqual(await ack(e, c, challenge: challenge, instance: a).error, .unauthorized)
        await aNil(await ack(e, c, challenge: challenge, instance: b).error)
    }

    func testControlInstanceNonceFormatIsValidated() async throws {
        // Bug caught: accepting short or odd-charset nonces as process bindings.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        for bad in ["short", String(repeating: "a", count: 129), "has space 0123456789", "slash/0123456789ab"] {
            await aEqual(await poll(e, c, instance: bad).error, .invalidInput, bad)
        }
        await aNil(await poll(e, c, instance: String(repeating: "a", count: 16)).error)
        await aNil(await poll(e, c, instance: String(repeating: "A_-", count: 42)).error)
    }

    func testCredentialFileNoLongerCarriesAgentInstance() async throws {
        // Bug caught: instance remaining an enrollment-time auth factor stored in the credential file.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let text = String(decoding: try Data(contentsOf: c.file), as: UTF8.self)
        XCTAssertFalse(text.contains("agentInstance"))
    }

    func testListResponseHelperInstanceChangesOnlyAcrossHelperRestarts() async throws {
        // Bug caught: incremental readers having no signal that the helper restarted under their cursor.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let r1 = await list(e, c), r2 = await list(e, c), r3 = await list(e, c, registry: restart(e))
        let first = try XCTUnwrap(object(r1)["helperInstance"]?.string)
        let again = try XCTUnwrap(object(r2)["helperInstance"]?.string)
        let other = try XCTUnwrap(object(r3)["helperInstance"]?.string)
        XCTAssertEqual(first, again); XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 16)
        let latest = await list(e, c)
        let page = try ManagedNotificationContract.validatePage(JSONEncoder().encode(latest.data))
        XCTAssertEqual(page.helperInstance, first)
    }

    func testContractRequiresHelperInstanceString() throws {
        // Bug caught: validator accepting a page without (or with a non-string) restart signal.
        func page(_ extra: [String: Any]) throws -> Data {
            var v: [String: Any] = ["schemaVersion": 1, "enrollmentEpoch": 1, "snapshotId": "abc", "highWaterMark": 0,
                                    "records": [], "nextPageToken": NSNull()]
            v.merge(extra) { $1 }
            return try JSONSerialization.data(withJSONObject: v)
        }
        XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page([:])))
        XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page(["helperInstance": 7])))
        XCTAssertNoThrow(try ManagedNotificationContract.validatePage(page(["helperInstance": "abcd"])))
    }

    func testContractRejectsBooleanAndFloatWhereIntegerRequired() throws {
        // Bug caught: `as? Int` on bridged NSNumber accepting true and 1.0 as integers.
        let valid = try validRecordJSON()
        func record(_ key: String, _ raw: String) -> Data {
            var text = String(decoding: try! bytes(valid), as: UTF8.self)
            let range = text.range(of: "\"\(key)\":\(valid[key]!)")!
            text.replaceSubrange(range, with: "\"\(key)\":\(raw)")
            return Data(text.utf8)
        }
        for raw in ["true", "1.0", "1e0"] {
            XCTAssertThrowsError(try ManagedNotificationContract.validateRecord(record("serviceRevision", raw)), raw) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
        }
        XCTAssertNoThrow(try ManagedNotificationContract.validateRecord(record("serviceRevision", "1")))
        func page(_ epoch: String, schema: String = "1") -> Data {
            Data(#"{"schemaVersion":\#(schema),"enrollmentEpoch":\#(epoch),"snapshotId":"abc","highWaterMark":0,"helperInstance":"h","records":[],"nextPageToken":null}"#.utf8)
        }
        for raw in ["true", "1.0"] {
            XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page(raw)), raw)
            XCTAssertThrowsError(try ManagedNotificationContract.validatePage(page("1", schema: raw)), "schema \(raw)")
        }
    }

    func testClientRejectsDuplicateKeysInRawResponseBeforeDecoding() async throws {
        // Bug caught: the client decoding a wire response with duplicate keys, letting last-key-wins pick the value.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        let body = #"{"requestId":null,"status":"completed","revision":1,"retryable":false,"data":{"schemaVersion":1,"enrollmentEpoch":1,"enrollmentEpoch":2,"snapshotId":"a","highWaterMark":0,"helperInstance":"h","records":[],"nextPageToken":null}}"#
        let client = ManagedNotificationClient(root: e.root, credentialFile: c.file, rawTransport: { _ in Data(body.utf8) })
        XCTAssertThrowsError(try client.list()) { XCTAssertEqual($0 as? ManagedError, .invalidInput) }
        let ok = body.replacingOccurrences(of: #""enrollmentEpoch":1,"enrollmentEpoch":2"#, with: #""enrollmentEpoch":1"#)
        let good = ManagedNotificationClient(root: e.root, credentialFile: c.file, rawTransport: { _ in Data(ok.utf8) })
        XCTAssertEqual(try good.list().helperInstance, "h")
    }

    func testCapabilitiesAreDerivedFromHelperConstants() throws {
        // Bug caught: --capabilities output drifting from what the helper actually enforces.
        let data = Data(try ManagedExportCapabilities.json().utf8)
        let decoded = try JSONDecoder().decode(ManagedExportCapabilities.self, from: data)
        XCTAssertEqual(decoded.exportStateSchemas, [ManagedExportStore.supportedSchema])
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.operations, ["notifications.list", "export.control.poll", "export.control.ack"])
    }

    func testControlCredentialStaysUsableForIdempotentRetryAfterAcknowledgement() async throws {
        // Bug caught: retiring the control credential at ack, so a lost ack response could never be retried.
        let e = try env()
        let c = try await enroll(e, [e.services[0]])
        await aNil(await poll(e, c).error)
        await aNil(await disable(e, c).error)
        let challenge = try await challenge(e, c)
        await aNil(await ack(e, c, challenge: challenge).error)
        await aNil(await ack(e, c, challenge: challenge).error)
        await aNil(await poll(e, c).error)
    }
}
