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
    private func rig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-fwd-\(UUID().uuidString)")
        let disk = try ManagedPersistence(root: root)
        let actor = ManagedActor(id: "fixture", scope: .user, credentialHash: ManagedDigest.hash(Data("fixture-token".utf8)))
        let registry = ManagedRegistry(persistence: disk, actors: [actor])
        let supervisor = ManagedSupervisor(registry: registry, key: Data("fixture-key".utf8), persistence: disk)
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
        let launch = ManagedLaunch(service: "relay", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: root.path, configurationFiles: [script.path])
        addTeardownBlock { [self] in
            for p in extras where p.isRunning { p.terminate() }
            for target in await registry.snapshot().flatMap({ $0.incarnations }) { _ = ManagedProcess.signal(target) }
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
        import http.server, sys
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
}
