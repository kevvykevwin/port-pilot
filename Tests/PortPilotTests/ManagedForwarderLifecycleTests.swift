import XCTest
import Foundation
@testable import PortPilotCore

/// A relay from a service's stable port to its backend must not outlive that backend.
final class ManagedForwarderLifecycleTests: XCTestCase, @unchecked Sendable {
    private struct Rig {
        let root: URL
        let registry: ManagedRegistry
        let supervisor: ManagedSupervisor
        let actor: ManagedActor
        let launch: ManagedLaunch
        func request(_ operation: String, revision: Int?, payload: [String: ManagedJSON]) -> ManagedRequest {
            ManagedRequest(operation: operation, actor: actor.id, credential: "fixture-token", expectedRevision: revision, payload: payload)
        }
    }
    private var extras: [Process] = []
    private func rig(launcher: Bool = false, observationWindow: TimeInterval = 30) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-fwd-\(UUID().uuidString)")
        let disk = try ManagedPersistence(root: root)
        let actor = ManagedActor(id: "fixture", scope: .user, credentialHash: ManagedDigest.hash(Data("fixture-token".utf8)))
        let registry = ManagedRegistry(persistence: disk, actors: [actor])
        let supervisor = ManagedSupervisor(registry: registry, key: Data("fixture-key".utf8), persistence: disk, observationWindow: observationWindow)
        let script = root.appendingPathComponent("server.py")
        try Data("""
        import os, sys, http.server, threading
        threading.Timer(90, lambda: os._exit(0)).start()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
        """.utf8).write(to: script)
        // The launcher stays alive and spawns the real server as a child, like nodemon does.
        let launcherScript = root.appendingPathComponent("launcher.py")
        try Data("""
        import os, sys, subprocess, time, threading
        threading.Timer(90, lambda: os._exit(0)).start()
        child = subprocess.Popen([sys.executable, sys.argv[1], sys.argv[2]])
        while True:
            child.poll()  # reap the child so its exit is observable while the launcher lives on
            time.sleep(0.1)
        """.utf8).write(to: launcherScript)
        let launch = launcher
            ? ManagedLaunch(service: "relay", executable: "/usr/bin/python3", arguments: [launcherScript.path, script.path, "{port}"], cwd: root.path, configurationFiles: [script.path, launcherScript.path])
            : ManagedLaunch(service: "relay", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: root.path, configurationFiles: [script.path])
        addTeardownBlock { [self] in
            for p in extras where p.isRunning { p.terminate() }
            for target in await registry.snapshot().flatMap({ $0.incarnations + ($0.transition?.newTargets ?? []) }) { _ = ManagedProcess.signal(target) }
            try? FileManager.default.removeItem(at: root)
        }
        return Rig(root: root, registry: registry, supervisor: supervisor, actor: actor, launch: launch)
    }
    private func waitUntil(_ limit: TimeInterval = 30, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("waitUntil timed out after \(limit)s")
    }
    private func current(_ rig: Rig) async throws -> ManagedService {
        let first = await rig.registry.snapshot().first
        return try XCTUnwrap(first)
    }
    private func run(_ rig: Rig, revision: Int) async throws {
        let response = await rig.supervisor.handle(rig.request("service.run", revision: revision, payload: ["launch": try .value(rig.launch)]))
        XCTAssertEqual(response.status, "accepted")
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle == "running" }
    }
    /// Returns the body served on the port, or nil when the connection fails.
    private func fetch(_ port: UInt16) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 2
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)/")!) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    private func stopThroughOperation(_ rig: Rig, _ service: ManagedService) async throws {
        var payload: [String: ManagedJSON] = ["serviceId": .string(service.id.uuidString), "action": .string("stop")]
        let proposed = await rig.supervisor.handle(rig.request("operation.propose", revision: service.revision, payload: payload))
        payload["operationId"] = .string(try XCTUnwrap(proposed.operationId).uuidString); payload["approved"] = .bool(true)
        _ = await rig.supervisor.handle(rig.request("decision.resolve", revision: service.revision, payload: payload))
        let executed = await rig.supervisor.handle(rig.request("operation.execute", revision: service.revision, payload: payload))
        XCTAssertNil(executed.error)
        try await waitUntil(30) { await rig.supervisor.reconcile(); return await rig.registry.snapshot().first?.lifecycle == "stopped" }
    }
    private func listenUnrelated(on port: UInt16, marker: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", """
        import http.server, sys, os, threading
        threading.Timer(60, lambda: os._exit(0)).start()
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.send_header('Content-Length', str(len(sys.argv[2]))); self.end_headers(); self.wfile.write(sys.argv[2].encode())
            def log_message(self, *a): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
        """, String(port), marker]
        try p.run()
        extras.append(p)
    }

    /// Bug caught: after a successful stop the relay kept listening on the stable port and forwarded to the
    /// old backend port, so an unrelated process that later bound that port was served at the stable URL.
    func testStoppedServiceStablePortNeverServesUnrelatedProcessOnOldBackendPort() async throws {
        let rig = try rig()
        try await run(rig, revision: 0)
        let running = try await current(rig)
        let stable = try XCTUnwrap(running.stablePort), backend = try XCTUnwrap(running.backendPort)
        let live = await fetch(stable)
        XCTAssertEqual(live, "ok")
        try await stopThroughOperation(rig, running)
        try listenUnrelated(on: backend, marker: "UNRELATED")
        try await waitUntil(10) { await self.fetch(backend) == "UNRELATED" }
        let direct = await fetch(backend)
        XCTAssertEqual(direct, "UNRELATED", "fixture listener must be up")
        await rig.supervisor.reconcile()
        let viaStable = await fetch(stable)
        XCTAssertNotEqual(viaStable, "UNRELATED", "stable port must not relay to a process that is not the service backend")
        XCTAssertNil(viaStable, "stable port must refuse connections while the service is stopped")
    }

    /// Bug caught: dropping the relay on stop must not break restart; the recreated relay must rebind the same stable port.
    func testRestartAfterStopRebindsStablePortToNewBackend() async throws {
        let rig = try rig()
        try await run(rig, revision: 0)
        let running = try await current(rig)
        let stable = try XCTUnwrap(running.stablePort), backend = try XCTUnwrap(running.backendPort)
        try await stopThroughOperation(rig, running)
        try listenUnrelated(on: backend, marker: "UNRELATED")
        await rig.supervisor.reconcile()
        let stopped = try await current(rig)
        try await run(rig, revision: stopped.revision)
        let restarted = try await current(rig)
        XCTAssertEqual(restarted.stablePort, stable)
        XCTAssertNotEqual(restarted.backendPort, backend)
        let body = await fetch(stable)
        XCTAssertEqual(body, "ok", "restart must serve the new backend on the same stable port")
    }

    /// Bug caught: an over-eager orphan sweep that stops the relay of a healthy running service.
    func testReconcileKeepsRelayOfRunningService() async throws {
        let rig = try rig()
        try await run(rig, revision: 0)
        let running = try await current(rig)
        let stable = try XCTUnwrap(running.stablePort)
        for _ in 0..<3 { await rig.supervisor.reconcile() }
        let body = await fetch(stable)
        XCTAssertEqual(body, "ok")
    }

    /// Bug caught: "some recorded process is alive" was treated as ownership. When the listening child dies but
    /// its launcher lives on (nodemon after a crash), the relay stayed open and served whatever bound the freed port.
    func testLauncherAliveButListenerDeadNeverServesUnrelatedProcess() async throws {
        let rig = try rig(launcher: true)
        try await run(rig, revision: 0)
        await rig.supervisor.reconcile()
        let running = try await current(rig)
        let stable = try XCTUnwrap(running.stablePort), backend = try XCTUnwrap(running.backendPort)
        let live = await fetch(stable)
        XCTAssertEqual(live, "ok")
        try await waitUntil { await rig.registry.snapshot().first?.incarnations.count ?? 0 >= 2 }
        let recorded = try await current(rig).incarnations
        let root = try XCTUnwrap(recorded.first)
        let children = recorded.dropFirst()
        XCTAssertFalse(children.isEmpty, "the server child must be a recorded descendant")
        for child in children { _ = ManagedProcess.signal(child) }
        try await waitUntil { children.allSatisfy(ManagedProcess.exitVerified) }
        XCTAssertEqual(ManagedProcess.incarnation(pid: root.pid), root, "the launcher must still be alive")
        for _ in 0..<2 { await rig.supervisor.reconcile() }
        try listenUnrelated(on: backend, marker: "UNRELATED")
        try await waitUntil(10) { await self.fetch(backend) == "UNRELATED" }
        await rig.supervisor.reconcile()
        let viaStable = await fetch(stable)
        XCTAssertNotEqual(viaStable, "UNRELATED", "a live launcher is not ownership of the backend port")
        XCTAssertNil(viaStable)
    }

    /// Bug caught: the sweep skipped any service with a leftover `transition` (finishReroute never clears it), so after a
    /// move ended for review and the backend later died, the relay forwarded to an unrelated process forever.
    func testLeftoverTransitionDoesNotKeepRelayOpenAfterBackendDies() async throws {
        let rig = try rig()
        try await run(rig, revision: 0)
        let running = try await current(rig)
        let stable = try XCTUnwrap(running.stablePort), backend = try XCTUnwrap(running.backendPort)
        // Narrow drive: open a real transition in the registry (no reroute task runs, as after a move that ended for review).
        var payload: [String: ManagedJSON] = ["serviceId": .string(running.id.uuidString), "action": .string("reroute")]
        let proposed = await rig.supervisor.handle(rig.request("operation.propose", revision: running.revision, payload: payload))
        payload["operationId"] = .string(try XCTUnwrap(proposed.operationId).uuidString); payload["approved"] = .bool(true)
        let resolved = await rig.supervisor.handle(rig.request("decision.resolve", revision: running.revision, payload: payload))
        XCTAssertNil(resolved.error)
        let spare = try ManagedProcess.availablePort(in: 30000...39999, excluding: [backend])
        _ = try await rig.registry.beginReroute(rig.request("operation.execute", revision: running.revision, payload: payload), backend: spare)
        let withTransition = try await current(rig)
        XCTAssertNotNil(withTransition.transition)
        XCTAssertNil(withTransition.fence)
        for target in withTransition.incarnations { _ = ManagedProcess.signal(target) }
        try await waitUntil { await rig.supervisor.reconcile(); return withTransition.incarnations.allSatisfy(ManagedProcess.exitVerified) }
        try listenUnrelated(on: backend, marker: "UNRELATED")
        try await waitUntil(10) { await self.fetch(backend) == "UNRELATED" }
        for _ in 0..<2 { await rig.supervisor.reconcile() }
        let viaStable = await fetch(stable)
        XCTAssertNotEqual(viaStable, "UNRELATED")
        XCTAssertNil(viaStable)
    }

    /// Bug caught: a gated relay must reopen when ownership returns; an unverified relay that never reopens breaks a
    /// service whose listener is restarted by a launcher (here: reconcile keeps forwarding for a healthy owner afterwards).
    func testHealthyServiceStillForwardsAfterRepeatedSweepsAndRestart() async throws {
        let rig = try rig()
        try await run(rig, revision: 0)
        let running = try await current(rig)
        let stable = try XCTUnwrap(running.stablePort)
        for _ in 0..<3 { await rig.supervisor.reconcile() }
        let body = await fetch(stable)
        XCTAssertEqual(body, "ok")
        try await stopThroughOperation(rig, running)
        await rig.supervisor.reconcile()
        let stopped = try await current(rig)
        try await run(rig, revision: stopped.revision)
        for _ in 0..<3 { await rig.supervisor.reconcile() }
        let again = await fetch(stable)
        XCTAssertEqual(again, "ok")
    }

    /// Bug caught: start() opened the relay right after resume(), before any scan proved the child owns the backend
    /// port, so while the service was still `starting` the stable URL served whatever else listened on that port.
    /// Construction: the child sleeps before binding (never owns the port during the check); once the registry
    /// publishes the backend port an unrelated listener takes it; the stable port must never relay its marker.
    func testStartingServiceNeverRelaysSquatterOnBackendPort() async throws {
        let rig = try rig()
        let slow = rig.root.appendingPathComponent("slow.py")
        try Data("import sys, time\ntime.sleep(40)\n".utf8).write(to: slow)
        let launch = ManagedLaunch(service: "relay", executable: "/usr/bin/python3", arguments: [slow.path, "{port}"], cwd: rig.root.path, configurationFiles: [slow.path])
        let response = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        XCTAssertEqual(response.status, "accepted")
        try await waitUntil { await rig.registry.snapshot().first?.backendPort != nil }
        let starting = try await current(rig)
        let stable = try XCTUnwrap(starting.stablePort), backend = try XCTUnwrap(starting.backendPort)
        try listenUnrelated(on: backend, marker: "SQUATTER")
        try await waitUntil(10) { await self.fetch(backend) == "SQUATTER" }
        for _ in 0..<8 {
            let lifecycle = await rig.registry.snapshot().first?.lifecycle
            XCTAssertEqual(lifecycle, "starting", "the check must run while readiness is still pending")
            let viaStable = await fetch(stable)
            XCTAssertNotEqual(viaStable, "SQUATTER", "stable port must not relay a process the child does not own")
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Bug caught: a gated relay that never reopens. A launcher respawns its server on the same port; after the sweep
    /// gated the relay (listener dead) and ownership returned (new recorded incarnation listens), reconcile must reopen it.
    func testGatedRelayReopensWhenLauncherRespawnsListener() async throws {
        let rig = try rig()
        let server = rig.root.appendingPathComponent("server.py")
        let respawner = rig.root.appendingPathComponent("respawn.py")
        try Data("""
        import os, sys, subprocess, time, threading
        threading.Timer(90, lambda: os._exit(0)).start()
        child = None
        while True:
            if child is None or child.poll() is not None:
                if child is not None: time.sleep(1.5)
                child = subprocess.Popen([sys.executable, sys.argv[1], sys.argv[2]])
            time.sleep(0.1)
        """.utf8).write(to: respawner)
        let launch = ManagedLaunch(service: "relay", executable: "/usr/bin/python3", arguments: [respawner.path, server.path, "{port}"], cwd: rig.root.path, configurationFiles: [server.path, respawner.path])
        let response = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        XCTAssertEqual(response.status, "accepted")
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle == "running" }
        let svc = try await current(rig)
        let stable = try XCTUnwrap(svc.stablePort)
        let live = await fetch(stable)
        XCTAssertEqual(live, "ok")
        try await waitUntil { await rig.registry.snapshot().first?.incarnations.count ?? 0 >= 2 }
        let first = try await current(rig).incarnations.dropFirst()
        for child in first { _ = ManagedProcess.signal(child) }
        try await waitUntil { first.allSatisfy(ManagedProcess.exitVerified) }
        await rig.supervisor.reconcile()
        let gated = await fetch(stable)
        XCTAssertNil(gated, "relay must be closed while no recorded process listens")
        try await waitUntil(20) { await rig.supervisor.reconcile(); return await self.fetch(stable) == "ok" }
    }

    /// Bug caught: a move's new backend dying while an old connection drains kept the stable port pointed at the
    /// dead backend for up to a minute (ending "drain_timeout"), instead of rolling back to the healthy old one.
    func testReplacementDyingDuringDrainRollsBackToOldBackend() async throws {
        let rig = try rig(observationWindow: 0)
        let script = rig.root.appendingPathComponent("named.py")
        try Data("""
        import os, sys, http.server, threading
        threading.Timer(90, lambda: os._exit(0)).start()
        port = sys.argv[1]
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = ('ready-' + port).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', int(port)), Handler).serve_forever()
        """.utf8).write(to: script)
        let launch = ManagedLaunch(service: "relay", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: rig.root.path,
                                   readinessMarker: "ready-", configurationFiles: [script.path], parallelSafe: true)
        let started = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        XCTAssertEqual(started.status, "accepted")
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle == "running" }
        let before = try await current(rig)
        let stable = try XCTUnwrap(before.stablePort), old = try XCTUnwrap(before.backendPort)
        let first = await fetch(stable)
        XCTAssertEqual(first, "ready-\(old)")
        // An idle connection on the old route keeps the drain waiting.
        let held = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = stable.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(held, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var payload: [String: ManagedJSON] = ["serviceId": .string(before.id.uuidString), "action": .string("reroute")]
        let proposed = await rig.supervisor.handle(rig.request("operation.propose", revision: before.revision, payload: payload))
        let id = try XCTUnwrap(proposed.operationId)
        payload["operationId"] = .string(id.uuidString); payload["approved"] = .bool(true)
        let resolved = await rig.supervisor.handle(rig.request("decision.resolve", revision: before.revision, payload: payload))
        XCTAssertNil(resolved.error)
        let accepted = await rig.supervisor.handle(rig.request("operation.execute", revision: before.revision, payload: payload))
        XCTAssertEqual(accepted.status, "accepted")
        try await waitUntil(40) { await rig.registry.snapshot().first?.transition?.phase == "switched" }
        let switched = try await current(rig)
        let replacement = try XCTUnwrap(switched.transition?.newTargets)
        XCTAssertFalse(replacement.isEmpty)
        for target in replacement { _ = ManagedProcess.signal(target) }
        // The drain would otherwise wait 60 s for the held connection; rollback must come well before that.
        try await waitUntil(20) { await rig.registry.operation(id: id)?.phase == "needs_review" }
        let outcome = await rig.registry.operation(id: id)?.outcome
        XCTAssertEqual(outcome, "rolled_back_replacement_retained_for_review")
        let after = try await current(rig)
        XCTAssertEqual(after.backendPort, old, "the stable port must point back at the old backend")
        let served = await fetch(stable)
        XCTAssertEqual(served, "ready-\(old)")
    }
}
