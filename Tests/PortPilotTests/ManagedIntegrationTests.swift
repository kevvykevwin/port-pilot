import XCTest
import Foundation
import Darwin
@testable import PortPilotCore

final class ManagedIntegrationTests: XCTestCase, @unchecked Sendable {
    private static func stopFixture(_ process: Process) {
        guard let identity = ManagedProcess.incarnation(pid: process.processIdentifier) else { return }
        _ = ManagedProcess.signal(identity)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ManagedProcess.incarnation(pid: identity.pid) == identity && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if ManagedProcess.incarnation(pid: identity.pid) == identity {
            _ = ProcessKiller.forceKill(pid: identity.pid, expectedStartTime: identity.startTime)
        }
    }
    private struct Helper {
        let process: Process
        let root: URL
        let credential: String
        var socket: String { root.appendingPathComponent("control.sock").path }
        func request(_ operation: String, revision: Int? = nil, payload: [String: ManagedJSON] = [:], id: String = UUID().uuidString) throws -> ManagedResponse {
            try ManagedSocket.request(ManagedRequest(requestId: id, operation: operation, actor: "fixture", credential: credential,
                                                     expectedRevision: revision, payload: payload), path: socket)
        }
    }
    private func helper() throws -> Helper {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = project.appendingPathComponent(".build/debug/PortPilotHelper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build PortPilotHelper before socket integration tests") }
        let root = URL(fileURLWithPath: "/tmp/pp-test-\(UUID().uuidString.prefix(8))")
        let enroll = Process(); let output = Pipe()
        enroll.executableURL = executable; enroll.arguments = ["--state-dir", root.path, "enroll", "fixture", "user"]
        enroll.standardOutput = output; enroll.standardError = FileHandle.nullDevice
        try enroll.run(); enroll.waitUntilExit(); XCTAssertEqual(enroll.terminationStatus, 0)
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let process = Process(); process.executableURL = executable; process.arguments = ["--state-dir", root.path, "serve"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            Self.stopFixture(process)
            try? FileManager.default.removeItem(at: root)
        }
        let helper = Helper(process: process, root: root, credential: try XCTUnwrap(credentials["credential"]))
        for _ in 0..<100 {
            if (try? helper.request("status").error) == nil && FileManager.default.fileExists(atPath: helper.socket) { return helper }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ManagedError.dependencyUnavailable
    }
    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
        ManagedSocket.configure(fd)
        var address = try ManagedSocket.address(path)
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw ManagedError.dependencyUnavailable }; return fd
    }
    func testO14RealSocketFragmentsCoalescedFramesAndSizeLimits() throws {
        let h = try helper()
        let req = ManagedRequest(operation: "status", actor: "fixture", credential: h.credential)
        let frame = ManagedWire.frame(try JSONEncoder().encode(req))
        let fd = try connect(h.socket); defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for byte in frame { try ManagedSocket.write(fd, data: Data([byte]), deadline: deadline) }
        let response = try ManagedSocket.receive(fd, limit: ManagedWire.responseLimit, deadline: deadline)
        XCTAssertNil(try JSONDecoder().decode(ManagedResponse.self, from: response).error)
        let coalesced = try connect(h.socket); defer { close(coalesced) }
        try ManagedSocket.write(coalesced, data: frame + frame, deadline: deadline)
        _ = try ManagedSocket.receive(coalesced, limit: ManagedWire.responseLimit, deadline: deadline)
        XCTAssertThrowsError(try ManagedSocket.receive(coalesced, limit: ManagedWire.responseLimit, deadline: deadline))
        for length: UInt32 in [0, 65537] {
            let connection = try connect(h.socket); defer { close(connection) }
            var big = length.bigEndian
            try ManagedSocket.write(connection, data: withUnsafeBytes(of: &big) { Data($0) }, deadline: deadline)
            let data = try ManagedSocket.receive(connection, limit: ManagedWire.responseLimit, deadline: deadline)
            XCTAssertEqual(try JSONDecoder().decode(ManagedResponse.self, from: data).error, .invalidInput)
        }
        let bad = try connect(h.socket); defer { close(bad) }
        try ManagedSocket.write(bad, data: ManagedWire.frame(Data(#"{"actor":"fixture","actor":"other"}"#.utf8)), deadline: deadline)
        let invalid = try ManagedSocket.receive(bad, limit: ManagedWire.responseLimit, deadline: deadline)
        XCTAssertEqual(try JSONDecoder().decode(ManagedResponse.self, from: invalid).error, .invalidInput)
    }
    func testO14AbsoluteDeadlineAndConnectionCap() throws {
        let h = try helper(); var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<32 { clients.append(try connect(h.socket)) }
        Thread.sleep(forTimeInterval: 0.1)
        let excess = try connect(h.socket); defer { close(excess) }
        XCTAssertThrowsError(try ManagedSocket.receive(excess, limit: ManagedWire.responseLimit, deadline: ProcessInfo.processInfo.systemUptime + 1))
        let start = ProcessInfo.processInfo.systemUptime
        // A slow partial header cannot extend the five-second accept deadline.
        try ManagedSocket.write(clients[0], data: Data([0]), deadline: start + 1)
        Thread.sleep(forTimeInterval: 2)
        try ManagedSocket.write(clients[0], data: Data([0]), deadline: start + 3)
        let data = try ManagedSocket.receive(clients[0], limit: ManagedWire.responseLimit, deadline: start + 5.5)
        XCTAssertNotNil(try JSONDecoder().decode(ManagedResponse.self, from: data).error)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5.5)
    }
    func testRealRerouteKeepsStableURLAndVerifiesOldExit() async throws {
        let h = try helper()
        let script = h.root.appendingPathComponent("reroute.py")
        try Data("""
        import http.server, sys, os, threading
        port = int(sys.argv[1])
        threading.Timer(90, lambda: os._exit(0)).start()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = ('ready-' + str(port)).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
        """.utf8).write(to: script)
        let launch = ManagedLaunch(service: "reroute", executable: "/usr/bin/python3", arguments: [script.path, "{port}"], cwd: h.root.path,
                                   readinessMarker: "ready-", configurationFiles: [script.path], parallelSafe: true)
        let start = try h.request("service.run", revision: 0, payload: ["launch": try .value(launch)])
        let startId = try XCTUnwrap(start.operationId)
        func operation(_ id: UUID) throws -> ManagedOperation {
            let response = try h.request("operation.inspect", payload: ["operationId": .string(id.uuidString)])
            return try JSONDecoder().decode(ManagedOperation.self, from: JSONEncoder().encode(try XCTUnwrap(response.data)))
        }
        let serviceId = try operation(startId).serviceId
        func service() throws -> ManagedServiceReport {
            let response = try h.request("service.inspect", payload: ["serviceId": .string(serviceId.uuidString)])
            return try JSONDecoder().decode(ManagedServiceReport.self, from: JSONEncoder().encode(try XCTUnwrap(response.data)))
        }
        addTeardownBlock {
            if let record = try? service() {
                for target in record.incarnations + (record.transition?.newTargets ?? []) { _ = ManagedProcess.signal(target) }
            }
        }
        for _ in 0..<100 {
            if try operation(startId).phase != "starting" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let before = try service()
        XCTAssertEqual(before.lifecycle, "running")
        let stable = try XCTUnwrap(before.stablePort), old = try XCTUnwrap(before.backendPort)
        var payload: [String: ManagedJSON] = ["serviceId": .string(serviceId.uuidString), "action": .string("reroute")]
        let proposed = try h.request("operation.propose", revision: before.revision, payload: payload)
        let id = try XCTUnwrap(proposed.operationId)
        payload["operationId"] = .string(id.uuidString); payload["approved"] = .bool(true)
        XCTAssertNil(try h.request("decision.resolve", revision: before.revision, payload: payload).error)
        let accepted = try h.request("operation.execute", revision: before.revision, payload: payload, id: "reroute-once")
        XCTAssertEqual(accepted.status, "accepted")
        XCTAssertEqual(try h.request("operation.execute", revision: before.revision, payload: payload, id: "reroute-once").operationId, id)
        for _ in 0..<400 {
            if try ["completed", "needs_review"].contains(operation(id).phase) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = try service(), outcome = try operation(id)
        XCTAssertEqual(outcome.outcome, "route_verified_old_exit_verified")
        XCTAssertEqual(after.stablePort, stable)
        XCTAssertNotEqual(after.backendPort, old)
        XCTAssertEqual(after.routeGeneration, 2)
        XCTAssertEqual(after.activeClaims.map(\.id), before.activeClaims.map(\.id))
        XCTAssertEqual(after.incarnations.count, 1)
        let (body, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(stable)/")!)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "ready-\(try XCTUnwrap(after.backendPort))")
        XCTAssertNotEqual(ManagedProcess.incarnation(pid: before.incarnations[0].pid), before.incarnations[0])
    }
    func testManagedLaunchProxyAndExplicitVerifiedStop() async throws {
        var h = try helper()
        let script = h.root.appendingPathComponent("server.py")
        try Data("""
        import argparse, http.server, threading, os, time, hashlib, base64
        parser = argparse.ArgumentParser()
        parser.add_argument('--port', type=int, required=True)
        args = parser.parse_args()
        threading.Timer(45, lambda: os._exit(0)).start()
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                if self.path == '/stream':
                    self.send_response(200)
                    self.send_header('Content-Length', str(10 * 1024 * 1024))
                    self.end_headers()
                    for _ in range(160):
                        self.wfile.write(b'x' * 65536)
                        self.wfile.flush()
                    return
                if self.path == '/events':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    self.wfile.write(b'data: first\\n\\n'); self.wfile.flush()
                    time.sleep(2)
                    self.wfile.write(b'data: second\\n\\n'); self.wfile.flush()
                    self.close_connection = True
                    return
                if self.path == '/ws':
                    key = self.headers['Sec-WebSocket-Key']
                    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                    self.send_response(101)
                    self.send_header('Upgrade', 'websocket')
                    self.send_header('Connection', 'Upgrade')
                    self.send_header('Sec-WebSocket-Accept', accept)
                    self.end_headers()
                    while True:
                        header = self.rfile.read(2)
                        if len(header) != 2: return
                        size = header[1] & 127
                        if size >= 126: return
                        mask = self.rfile.read(4)
                        payload = self.rfile.read(size)
                        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
                        self.wfile.write(bytes([header[0], len(payload)]) + payload); self.wfile.flush()
                        if header[0] & 15 == 8: return
                body = b'portpilot-disposable-fixture'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
        """.utf8).write(to: script)
        let launch = ManagedLaunch(service: "fixture", executable: "/usr/bin/python3", arguments: [script.path, "--port", "{port}"], cwd: h.root.path,
                                   readinessPath: "/health", readinessMarker: "portpilot-disposable-fixture", configurationFiles: [script.path])
        let payload: [String: ManagedJSON] = ["launch": try .value(launch)]
        // Disconnect after sending; a committed launch must outlive the client.
        let detachedRequest = ManagedRequest(requestId: "launch-once", operation: "service.run", actor: "fixture", credential: h.credential,
                                             expectedRevision: 0, payload: payload)
        let disconnected = try connect(h.socket)
        try ManagedSocket.write(disconnected, data: ManagedWire.frame(JSONEncoder().encode(detachedRequest)), deadline: ProcessInfo.processInfo.systemUptime + 2)
        close(disconnected)
        let started = try h.request("service.run", revision: 0, payload: payload, id: "launch-once")
        XCTAssertNil(started.error); XCTAssertEqual(started.status, "accepted")
        let repeated = try h.request("service.run", revision: 0, payload: payload, id: "launch-once")
        XCTAssertEqual(repeated.operationId, started.operationId)
        let operationId = try XCTUnwrap(started.operationId)
        var operation: ManagedOperation?
        for _ in 0..<150 {
            let response = try h.request("operation.inspect", payload: ["operationId": .string(operationId.uuidString)])
            operation = try JSONDecoder().decode(ManagedOperation.self, from: JSONEncoder().encode(try XCTUnwrap(response.data)))
            if operation?.phase != "starting" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(operation?.phase, "completed", "\(String(describing: operation))")
        let serviceId = try XCTUnwrap(operation?.serviceId)
        var inspected = try h.request("service.inspect", payload: ["serviceId": .string(serviceId.uuidString)])
        guard case .object(let fields) = inspected.data else { return XCTFail("missing service") }
        guard case .array(let identities) = fields["incarnations"], let first = identities.first else { return XCTFail("missing process") }
        let identity = try JSONDecoder().decode(ManagedIncarnation.self, from: JSONEncoder().encode(first))
        addTeardownBlock { _ = ManagedProcess.signal(identity) }
        let stable = try XCTUnwrap(fields["stablePort"]?.integer)
        let reused = try h.request("service.run", revision: inspected.revision, payload: payload)
        XCTAssertNil(reused.error); XCTAssertEqual(reused.status, "completed")
        inspected = try h.request("service.inspect", payload: ["serviceId": .string(serviceId.uuidString)])
        guard case .object(let reusedFields) = inspected.data else { return XCTFail("missing reused service") }
        XCTAssertEqual(reusedFields["incarnations"], fields["incarnations"])
        let (bytes, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(stable)/health")!)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "portpilot-disposable-fixture")
        let (streamed, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(stable)/stream")!)
        XCTAssertEqual(streamed.count, 10 * 1024 * 1024)
        let began = ProcessInfo.processInfo.systemUptime
        let (events, _) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(stable)/events")!)
        var lines = events.lines.makeAsyncIterator()
        let firstEvent = try await lines.next()
        XCTAssertEqual(firstEvent, "data: first")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5, "SSE must arrive before the stream completes")
        let websocket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(stable)/ws")!)
        websocket.resume()
        try await websocket.send(.string("portpilot-echo"))
        let echoed = try await websocket.receive()
        if case .string(let text) = echoed { XCTAssertEqual(text, "portpilot-echo") } else { XCTFail("wrong WebSocket response") }
        websocket.cancel(with: .normalClosure, reason: nil)
        // Foreground helper restart preserves the child, published port and
        // claims. This is deliberately not a launchd upgrade-survival claim.
        let oldProcess = h.process
        Self.stopFixture(oldProcess)
        XCTAssertEqual(ManagedProcess.incarnation(pid: identity.pid), identity)
        let replacement = Process(); replacement.executableURL = oldProcess.executableURL
        replacement.arguments = oldProcess.arguments
        replacement.standardOutput = FileHandle.nullDevice; replacement.standardError = FileHandle.nullDevice
        try replacement.run()
        addTeardownBlock { Self.stopFixture(replacement) }
        h = Helper(process: replacement, root: h.root, credential: h.credential)
        var recovered = false
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 0.5
        let recoverySession = URLSession(configuration: config)
        defer { recoverySession.invalidateAndCancel() }
        for _ in 0..<30 {
            if let (body, _) = try? await recoverySession.data(from: URL(string: "http://127.0.0.1:\(stable)/health")!),
               String(decoding: body, as: UTF8.self) == "portpilot-disposable-fixture" { recovered = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(recovered)
        let restored = try h.request("service.inspect", payload: ["serviceId": .string(serviceId.uuidString)])
        guard case .object(let restoredFields) = restored.data else { return XCTFail("missing restored service") }
        XCTAssertEqual(restoredFields["stablePort"]?.integer, stable)
        XCTAssertEqual(restoredFields["claims"], reusedFields["claims"])
        XCTAssertEqual(restoredFields["lifecycle"]?.string, "needs_review")
        var p: [String: ManagedJSON] = ["serviceId": .string(serviceId.uuidString), "action": .string("stop")]
        let proposal = try h.request("operation.propose", revision: inspected.revision, payload: p)
        let stopId = try XCTUnwrap(proposal.operationId)
        p["operationId"] = .string(stopId.uuidString); p["approved"] = .bool(true)
        XCTAssertNil(try h.request("decision.resolve", revision: inspected.revision, payload: p).error)
        let executed = try h.request("operation.execute", revision: inspected.revision, payload: p)
        XCTAssertEqual(executed.status, "accepted")
        for _ in 0..<40 {
            if ManagedProcess.incarnation(pid: identity.pid) != identity { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(ManagedProcess.incarnation(pid: identity.pid), identity)
        // Unknown descendants are explicitly unresolved, not a false whole-tree stop.
        try await Task.sleep(for: .seconds(1.1))
        let stopped = try h.request("operation.inspect", payload: ["operationId": .string(stopId.uuidString)])
        let stoppedOp = try JSONDecoder().decode(ManagedOperation.self, from: JSONEncoder().encode(try XCTUnwrap(stopped.data)))
        XCTAssertEqual(stoppedOp.outcome, "known_processes_exited_tree_unverified")
    }
}
