import XCTest
import Foundation
import Network
import Darwin
@testable import PortPilotCore

final class ManagedForwarderTests: XCTestCase {
    func testGenerationSwapPinsExistingConnectionsAndRejectsStableCollision() throws {
        let old = try EchoBackend(marker: "old"); defer { old.stop() }
        let new = try EchoBackend(marker: "new"); defer { new.stop() }
        let port = try ManagedProcess.availablePort(in: 40000...49000, excluding: [old.port, new.port])
        let proxy = try ManagedForwarder(stablePort: port, backendPort: old.port); defer { proxy.stop() }
        XCTAssertThrowsError(try ManagedForwarder(stablePort: port, backendPort: new.port))
        let first = try connect(port); defer { close(first) }
        XCTAssertEqual(try read(first, count: 3), "old")
        XCTAssertEqual(proxy.connectionCount(generation: 1), 1)
        proxy.switchBackend(to: new.port, generation: 2)
        let second = try connect(port); defer { close(second) }
        XCTAssertEqual(try read(second, count: 3), "new")
        try ManagedSocket.write(first, data: Data("old-still-connected".utf8), deadline: ProcessInfo.processInfo.systemUptime + 2)
        XCTAssertEqual(try read(first, count: 19), "old-still-connected")
        XCTAssertEqual(proxy.connectionCount(generation: 1), 1)
        XCTAssertEqual(proxy.connectionCount(generation: 2), 1)
    }
    func testSocketWriteDeadlineWithStalledReader() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        ManagedSocket.configure(fds[0]); ManagedSocket.configure(fds[1])
        var buffer: Int32 = 4096
        _ = setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ManagedSocket.write(fds[0], data: Data(repeating: 1, count: 1_048_576), deadline: began + 0.2))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
    }
    func testHundredRoutesTwoHundredConnectionsAndGlobalCap() throws {
        let backend = try EchoBackend(marker: "ok"); defer { backend.stop() }
        var proxies: [ManagedForwarder] = [], clients: [Int32] = [], ports: Set<UInt16> = [backend.port]
        defer { clients.forEach { close($0) }; proxies.forEach { $0.stop() } }
        for _ in 0..<100 {
            let port = try ManagedProcess.availablePort(in: 40000...49000, excluding: ports)
            ports.insert(port)
            let proxy = try ManagedForwarder(stablePort: port, backendPort: backend.port)
            proxies.append(proxy)
            for _ in 0..<2 {
                let fd = try connect(port); clients.append(fd)
                XCTAssertEqual(try read(fd, count: 2), "ok")
            }
        }
        XCTAssertEqual(proxies.reduce(0) { $0 + $1.connectionCount(generation: 1) }, 200)
        let extraPort = try ManagedProcess.availablePort(in: 40000...49000, excluding: ports)
        let extra = try ManagedForwarder(stablePort: extraPort, backendPort: backend.port); defer { extra.stop() }
        let rejected = try connect(extraPort); defer { close(rejected) }
        XCTAssertThrowsError(try read(rejected, count: 2))
        XCTAssertEqual(extra.connectionCount(generation: 1), 0)
        for fd in clients {
            try ManagedSocket.write(fd, data: Data("ping".utf8), deadline: ProcessInfo.processInfo.systemUptime + 2)
            XCTAssertEqual(try read(fd, count: 4), "ping")
        }
    }
    private func connect(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); throw ManagedError.dependencyUnavailable }
        ManagedSocket.configure(fd); return fd
    }
    private func read(_ fd: Int32, count: Int) throws -> String {
        String(decoding: try ManagedSocket.read(fd, count: count, deadline: ProcessInfo.processInfo.systemUptime + 2), as: UTF8.self)
    }
}

private final class EchoBackend: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "portpilot.fixture.echo")
    private var connections: [NWConnection] = []
    let port: UInt16
    init(marker: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port?.rawValue else { throw ManagedError.portUnavailable }
        self.port = port
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    connection.send(content: Data(marker.utf8), completion: .contentProcessed { _ in })
                    self?.echo(connection)
                }
            }
            connection.start(queue: self.queue)
        }
    }
    func stop() {
        queue.sync {
            listener.cancel()
            for c in connections { c.stateUpdateHandler = nil; c.cancel() }
            connections.removeAll()
        }
    }
    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard error == nil, !complete else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.echo(connection) })
        }
    }
}
