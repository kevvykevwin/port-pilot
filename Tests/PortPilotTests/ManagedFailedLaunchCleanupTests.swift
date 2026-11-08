import XCTest
import Foundation
@testable import PortPilotCore

/// A launch that fails after the child was resumed must not leave that child listening.
final class ManagedFailedLaunchCleanupTests: XCTestCase, @unchecked Sendable {
    private struct Rig {
        let root: URL
        let registry: ManagedRegistry
        let supervisor: ManagedSupervisor
        let actor: ManagedActor
        func request(_ operation: String, revision: Int?, payload: [String: ManagedJSON]) -> ManagedRequest {
            ManagedRequest(operation: operation, actor: actor.id, credential: "fixture-token", expectedRevision: revision, payload: payload)
        }
    }
    private func rig(timeout: TimeInterval) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-failed-\(UUID().uuidString)")
        let disk = try ManagedPersistence(root: root)
        let actor = ManagedActor(id: "fixture", scope: .user, credentialHash: ManagedDigest.hash(Data("fixture-token".utf8)))
        let registry = ManagedRegistry(persistence: disk, actors: [actor])
        let supervisor = ManagedSupervisor(registry: registry, key: Data("fixture-key".utf8), persistence: disk, readinessTimeout: timeout)
        let rig = Rig(root: root, registry: registry, supervisor: supervisor, actor: actor)
        addTeardownBlock {
            for target in await registry.snapshot().flatMap({ $0.incarnations + ($0.transition?.newTargets ?? []) }) { _ = ManagedProcess.signal(target) }
            try? FileManager.default.removeItem(at: root)
        }
        return rig
    }
    private func write(_ code: String, in root: URL) throws -> URL {
        let script = root.appendingPathComponent("server.py")
        try Data(code.utf8).write(to: script)
        return script
    }
    private func waitUntil(_ limit: TimeInterval = 30, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Bug caught: readiness failure left the resumed child (and its descendant) listening forever in needs_review.
    func testReadinessFailureTerminatesChildTreeAndLeavesServiceRestartable() async throws {
        let rig = try rig(timeout: 3)
        let script = try write("""
        import os, sys, http.server, threading, subprocess
        threading.Timer(60, lambda: os._exit(0)).start()
        subprocess.Popen(['/bin/sleep', '60'])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(500); self.send_header('Content-Length', '0'); self.end_headers()
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
        """, in: rig.root)
        let launch = ManagedLaunch(service: "never-ready", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: rig.root.path, configurationFiles: [script.path])
        let accepted = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        XCTAssertEqual(accepted.status, "accepted")
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle != "starting" }
        let first = await rig.registry.snapshot().first
        let failed = try XCTUnwrap(first)
        XCTAssertEqual(failed.lifecycle, "needs_review")
        XCTAssertGreaterThanOrEqual(failed.incarnations.count, 2, "the descendant must have been recorded")
        for target in failed.incarnations {
            XCTAssertTrue(ManagedProcess.exitVerified(target), "pid \(target.pid) survived a failed launch")
        }
        let again = await rig.supervisor.handle(rig.request("service.run", revision: failed.revision, payload: ["launch": try .value(launch)]))
        XCTAssertNil(again.error, "a fully cleaned failed launch must be restartable")
        XCTAssertEqual(again.status, "accepted")
    }

    /// Bug caught: a failed replacement backend kept running, or cleanup also killed the old backend that still serves.
    func testFailedReplacementIsTerminatedAndOldBackendKeepsServing() async throws {
        let rig = try rig(timeout: 8)
        let marker = rig.root.appendingPathComponent("first-port")
        let script = try write("""
        import os, sys, http.server, threading
        port = int(sys.argv[1]); marker = sys.argv[2]
        threading.Timer(90, lambda: os._exit(0)).start()
        first = not os.path.exists(marker)
        if first: open(marker, 'w').write(str(port))
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if first else 500); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
        """, in: rig.root)
        let launch = ManagedLaunch(service: "replace-fails", executable: "/usr/bin/python3", arguments: [script.path, "{port}", marker.path],
                                   cwd: rig.root.path, configurationFiles: [script.path], parallelSafe: true)
        _ = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle == "running" }
        let firstBefore = await rig.registry.snapshot().first
        let before = try XCTUnwrap(firstBefore)
        XCTAssertEqual(before.lifecycle, "running")
        var payload: [String: ManagedJSON] = ["serviceId": .string(before.id.uuidString), "action": .string("reroute")]
        let proposed = await rig.supervisor.handle(rig.request("operation.propose", revision: before.revision, payload: payload))
        let id = try XCTUnwrap(proposed.operationId)
        payload["operationId"] = .string(id.uuidString); payload["approved"] = .bool(true)
        let resolved = await rig.supervisor.handle(rig.request("decision.resolve", revision: before.revision, payload: payload))
        XCTAssertNil(resolved.error)
        let executed = await rig.supervisor.handle(rig.request("operation.execute", revision: before.revision, payload: payload))
        XCTAssertEqual(executed.status, "accepted")
        try await waitUntil(40) { await rig.registry.snapshot().first?.transition?.phase == "needs_review" }
        let firstAfter = await rig.registry.snapshot().first
        let after = try XCTUnwrap(firstAfter)
        let replacement = try XCTUnwrap(after.transition?.newTargets)
        XCTAssertFalse(replacement.isEmpty)
        for target in replacement { XCTAssertTrue(ManagedProcess.exitVerified(target), "replacement pid \(target.pid) survived") }
        for target in before.incarnations { XCTAssertEqual(ManagedProcess.incarnation(pid: target.pid), target, "old backend must keep running") }
    }
}
