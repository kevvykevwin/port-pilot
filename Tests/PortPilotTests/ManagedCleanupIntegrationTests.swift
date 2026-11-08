import XCTest
import Foundation
@testable import PortPilotCore

final class ManagedCleanupIntegrationTests: XCTestCase, @unchecked Sendable {
    func testRealReleaseCleanupRequiresKernelTreeProof() async throws {
        for forks in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-cleanup-\(UUID().uuidString)")
            let disk = try ManagedPersistence(root: root)
            let clock = CleanupClock()
            let actor = ManagedActor(id: "fixture", scope: .owner, credentialHash: ManagedDigest.hash(Data("fixture-token".utf8)))
            let registry = ManagedRegistry(persistence: disk, actors: [actor], uptime: { clock.value })
            let supervisor = ManagedSupervisor(registry: registry, key: Data("fixture-key".utf8), persistence: disk)
            let script = root.appendingPathComponent("server.py")
            let forkCode = forks ? "pid=os.fork()\nif pid == 0: os._exit(0)\nos.waitpid(pid,0)\n" : ""
            try Data(("import os,sys,http.server,threading\n" + forkCode + """
            threading.Timer(30, lambda: os._exit(0)).start()
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.send_header('Content-Length', '2')
                    self.end_headers()
                    self.wfile.write(b'ok')
                def log_message(self, *args): pass
            http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
            """).utf8).write(to: script)
            let launch = ManagedLaunch(service: "cleanup", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: root.path, configurationFiles: [script.path])
            let request = ManagedRequest(operation: "service.run", actor: actor.id, credential: "fixture-token", expectedRevision: 0, payload: ["launch": try .value(launch)])
            let accepted = await supervisor.handle(request)
            XCTAssertEqual(accepted.status, "accepted")
            for _ in 0..<100 {
                if await registry.snapshot().first?.lifecycle == "running" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let snapshot = await registry.snapshot()
            let service = try XCTUnwrap(snapshot.first)
            addTeardownBlock {
                for identity in await registry.snapshot().flatMap(\.incarnations) { _ = ManagedProcess.signal(identity) }
                await supervisor.reconcile()
                try? FileManager.default.removeItem(at: root)
            }
            XCTAssertEqual(service.lifecycle, "running")
            XCTAssertEqual(service.treeComplete, !forks)
            let release = ManagedRequest(operation: "claim.release", actor: actor.id, credential: "fixture-token", expectedRevision: service.revision,
                payload: ["serviceId": .string(service.id.uuidString), "claimId": .string(try XCTUnwrap(service.activeClaims.first).id.uuidString)])
            let released = await supervisor.handle(release)
            XCTAssertNil(released.error)
            clock.advance(59)
            await supervisor.reconcile()
            XCTAssertEqual(ManagedProcess.incarnation(pid: service.incarnations[0].pid), service.incarnations[0])
            clock.advance(2)
            await supervisor.reconcile()
            if forks {
                XCTAssertEqual(ManagedProcess.incarnation(pid: service.incarnations[0].pid), service.incarnations[0], "A consumed fork event must still block cleanup")
                let retained = await registry.snapshot()[0]
                XCTAssertEqual(retained.lifecycle, "release_pending")
            } else {
                for _ in 0..<100 {
                    await supervisor.reconcile()
                    if await registry.snapshot()[0].lifecycle == "stopped" { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let stopped = await registry.snapshot()[0]
                XCTAssertEqual(stopped.lifecycle, "stopped")
                XCTAssertNil(stopped.fence)
                XCTAssertNotEqual(ManagedProcess.incarnation(pid: service.incarnations[0].pid), service.incarnations[0])
                var restart = request
                restart.requestId = UUID().uuidString; restart.expectedRevision = stopped.revision
                let acceptedRestart = await supervisor.handle(restart)
                XCTAssertEqual(acceptedRestart.status, "accepted")
                for _ in 0..<100 {
                    if await registry.snapshot()[0].lifecycle == "running" { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let restarted = await registry.snapshot()[0]
                XCTAssertEqual(restarted.lifecycle, "running")
                XCTAssertEqual(restarted.id, service.id)
                XCTAssertEqual(restarted.stablePort, service.stablePort)
                XCTAssertEqual(restarted.routeGeneration, service.routeGeneration + 1)
                XCTAssertNotEqual(restarted.incarnations, service.incarnations)
            }
        }
    }
    func testSupervisorRunRestartsNeedsReviewServiceOnceItsProcessesAreGone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-review-\(UUID().uuidString)")
        let disk = try ManagedPersistence(root: root)
        let actor = ManagedActor(id: "fixture", scope: .owner, credentialHash: ManagedDigest.hash(Data("fixture-token".utf8)))
        let registry = ManagedRegistry(persistence: disk, actors: [actor])
        let supervisor = ManagedSupervisor(registry: registry, key: Data("fixture-key".utf8), persistence: disk)
        let script = root.appendingPathComponent("server.py")
        try Data("""
        import os,sys,http.server
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
        """.utf8).write(to: script)
        let launch = ManagedLaunch(service: "review", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: root.path, configurationFiles: [script.path])
        let request = ManagedRequest(operation: "service.run", actor: actor.id, credential: "fixture-token", expectedRevision: 0, payload: ["launch": try .value(launch)])
        let accepted = await supervisor.handle(request)
        XCTAssertEqual(accepted.status, "accepted")
        for _ in 0..<100 {
            if await registry.snapshot().first?.lifecycle == "running" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let runningSnapshot = await registry.snapshot()
        let running = try XCTUnwrap(runningSnapshot.first)
        XCTAssertEqual(running.lifecycle, "running")
        addTeardownBlock {
            for identity in await registry.snapshot().flatMap(\.incarnations) { _ = ManagedProcess.signal(identity) }
            try? FileManager.default.removeItem(at: root)
        }
        // The service dies behind the helper's back: reconcile flags needs_review.
        for identity in running.incarnations { _ = ManagedProcess.signal(identity) }
        var review = running
        for _ in 0..<100 {
            await supervisor.reconcile()
            let snap = await registry.snapshot()
            review = try XCTUnwrap(snap.first)
            if review.lifecycle == "needs_review" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(review.lifecycle, "needs_review")
        for _ in 0..<100 {
            if running.incarnations.allSatisfy({ ManagedProcess.incarnation(pid: $0.pid) != $0 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        var again = request
        again.requestId = UUID().uuidString; again.expectedRevision = review.revision
        let restarted = await supervisor.handle(again)
        XCTAssertNil(restarted.error, "needs_review with every process gone must route to restart, not incompatible_launch")
        XCTAssertEqual(restarted.status, "accepted")
        for _ in 0..<100 {
            if await registry.snapshot()[0].lifecycle == "running" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let after = await registry.snapshot()[0]
        XCTAssertEqual(after.lifecycle, "running"); XCTAssertEqual(after.id, running.id)
    }
}

private final class CleanupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    var value: TimeInterval { lock.withLock { elapsed } }
    func advance(_ value: TimeInterval) { lock.withLock { elapsed += value } }
}
