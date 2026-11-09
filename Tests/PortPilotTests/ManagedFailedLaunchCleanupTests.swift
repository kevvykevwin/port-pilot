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
        var replacement: [ManagedIncarnation] = []
        try await waitUntil(40) {
            if let seen = await rig.registry.snapshot().first?.transition?.newTargets, !seen.isEmpty { replacement = seen }
            return await rig.registry.operation(id: id)?.phase == "needs_review"
        }
        XCTAssertFalse(replacement.isEmpty)
        for target in replacement { XCTAssertTrue(ManagedProcess.exitVerified(target), "replacement pid \(target.pid) survived") }
        for target in before.incarnations { XCTAssertEqual(ManagedProcess.incarnation(pid: target.pid), target, "old backend must keep running") }
    }

    /// Bug caught: terminating the failed replacement left its dead root merged into incarnations with the transition open,
    /// so the next reconcile flipped the service to needs_review and the still-serving old backend could no longer be stopped.
    func testFailedMoveMustNotStrandOldBackendInNeedsReview() async throws {
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
        let launch = ManagedLaunch(service: "replace-fails-stop", executable: "/usr/bin/python3", arguments: [script.path, "{port}", marker.path],
                                   cwd: rig.root.path, configurationFiles: [script.path], parallelSafe: true)
        _ = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle == "running" }
        let firstBefore = await rig.registry.snapshot().first
        let before = try XCTUnwrap(firstBefore)
        var payload: [String: ManagedJSON] = ["serviceId": .string(before.id.uuidString), "action": .string("reroute")]
        let proposed = await rig.supervisor.handle(rig.request("operation.propose", revision: before.revision, payload: payload))
        let id = try XCTUnwrap(proposed.operationId)
        payload["operationId"] = .string(id.uuidString); payload["approved"] = .bool(true)
        _ = await rig.supervisor.handle(rig.request("decision.resolve", revision: before.revision, payload: payload))
        let executed = await rig.supervisor.handle(rig.request("operation.execute", revision: before.revision, payload: payload))
        XCTAssertEqual(executed.status, "accepted")
        try await waitUntil(40) { await rig.registry.operation(id: id)?.phase == "needs_review" }
        await rig.supervisor.reconcile()
        await rig.supervisor.reconcile()
        let afterSnapshot = await rig.registry.snapshot().first
        let after = try XCTUnwrap(afterSnapshot)
        XCTAssertEqual(after.lifecycle, "running", "a failed move must not flip the service to needs_review")
        XCTAssertNil(after.transition)
        XCTAssertEqual(after.incarnations, before.incarnations)
        let operation = await rig.registry.operation(id: id)
        XCTAssertEqual(operation?.outcome, "preparation_failed_replacement_stopped")

        // The old backend must still be stoppable through the normal propose -> decide -> execute path.
        var stop: [String: ManagedJSON] = ["serviceId": .string(after.id.uuidString), "action": .string("stop")]
        let stopProposal = await rig.supervisor.handle(rig.request("operation.propose", revision: after.revision, payload: stop))
        XCTAssertNil(stopProposal.error)
        stop["operationId"] = .string(try XCTUnwrap(stopProposal.operationId).uuidString); stop["approved"] = .bool(true)
        let decided = await rig.supervisor.handle(rig.request("decision.resolve", revision: after.revision, payload: stop))
        XCTAssertNil(decided.error)
        let stopped = await rig.supervisor.handle(rig.request("operation.execute", revision: after.revision, payload: stop))
        XCTAssertNil(stopped.error, "stop must not fail on identity_unavailable")
        for target in before.incarnations {
            try await waitUntil(10) { await rig.supervisor.reconcile(); return ManagedProcess.exitVerified(target) }
            XCTAssertTrue(ManagedProcess.exitVerified(target), "old backend pid \(target.pid) must receive the stop signal")
        }
    }

    /// Bug caught: a replacement that forked can never verify its tree, so the failed move fell back to merging it into incarnations and left its dead root merged into incarnations with the transition open,
    /// so the next reconcile flipped the service to needs_review and the still-serving old backend could no longer be stopped.
    func testFailedMoveOfForkedReplacementMustNotStrandOldBackendInNeedsReview() async throws {
        let rig = try rig(timeout: 8)
        let marker = rig.root.appendingPathComponent("first-port")
        let script = try write("""
        import os, sys, http.server, threading
        port = int(sys.argv[1]); marker = sys.argv[2]
        threading.Timer(90, lambda: os._exit(0)).start()
        first = not os.path.exists(marker)
        if not first:
            pid = os.fork()
            if pid == 0: os._exit(0)
            os.waitpid(pid, 0)
        if first: open(marker, 'w').write(str(port))
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if first else 500); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
        """, in: rig.root)
        let launch = ManagedLaunch(service: "replace-fails-fork", executable: "/usr/bin/python3", arguments: [script.path, "{port}", marker.path],
                                   cwd: rig.root.path, configurationFiles: [script.path], parallelSafe: true)
        _ = await rig.supervisor.handle(rig.request("service.run", revision: 0, payload: ["launch": try .value(launch)]))
        try await waitUntil { await rig.registry.snapshot().first?.lifecycle == "running" }
        let firstBefore = await rig.registry.snapshot().first
        let before = try XCTUnwrap(firstBefore)
        var payload: [String: ManagedJSON] = ["serviceId": .string(before.id.uuidString), "action": .string("reroute")]
        let proposed = await rig.supervisor.handle(rig.request("operation.propose", revision: before.revision, payload: payload))
        let id = try XCTUnwrap(proposed.operationId)
        payload["operationId"] = .string(id.uuidString); payload["approved"] = .bool(true)
        _ = await rig.supervisor.handle(rig.request("decision.resolve", revision: before.revision, payload: payload))
        let executed = await rig.supervisor.handle(rig.request("operation.execute", revision: before.revision, payload: payload))
        XCTAssertEqual(executed.status, "accepted")
        try await waitUntil(40) { await rig.registry.operation(id: id)?.phase == "needs_review" }
        await rig.supervisor.reconcile()
        await rig.supervisor.reconcile()
        let afterSnapshot = await rig.registry.snapshot().first
        let after = try XCTUnwrap(afterSnapshot)
        XCTAssertEqual(after.lifecycle, "running", "a failed move must not flip the service to needs_review")
        XCTAssertNil(after.transition)
        XCTAssertEqual(after.incarnations, before.incarnations)
        let operation = await rig.registry.operation(id: id)
        XCTAssertEqual(operation?.outcome, "preparation_failed_replacement_tree_unverified")

        // The old backend must still be stoppable through the normal propose -> decide -> execute path.
        var stop: [String: ManagedJSON] = ["serviceId": .string(after.id.uuidString), "action": .string("stop")]
        let stopProposal = await rig.supervisor.handle(rig.request("operation.propose", revision: after.revision, payload: stop))
        XCTAssertNil(stopProposal.error)
        stop["operationId"] = .string(try XCTUnwrap(stopProposal.operationId).uuidString); stop["approved"] = .bool(true)
        let decided = await rig.supervisor.handle(rig.request("decision.resolve", revision: after.revision, payload: stop))
        XCTAssertNil(decided.error)
        let stopped = await rig.supervisor.handle(rig.request("operation.execute", revision: after.revision, payload: stop))
        XCTAssertNil(stopped.error, "stop must not fail on identity_unavailable")
        for target in before.incarnations {
            try await waitUntil(10) { await rig.supervisor.reconcile(); return ManagedProcess.exitVerified(target) }
            XCTAssertTrue(ManagedProcess.exitVerified(target), "old backend pid \(target.pid) must receive the stop signal")
        }
    }
}
