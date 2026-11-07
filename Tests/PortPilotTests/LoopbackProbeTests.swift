import Darwin
import Foundation
import XCTest
@testable import PortPilotCore

final class LoopbackProbeTests: XCTestCase {
    private enum SocketError: Error { case failed(String, Int32) }

    private var openFDs: [Int32] = []

    override func tearDown() {
        openFDs.forEach { close($0) }
        openFDs = []
        super.tearDown()
    }

    /// Binds a TCP socket on a loopback address (port 0 or a fixed port).
    /// Returns the fd and the assigned port. `listening: false` leaves it bound only.
    private func bindSocket(
        _ address: LoopbackAddress, port: UInt16 = 0, listening: Bool
    ) throws -> (fd: Int32, port: UInt16) {
        let family = address == .ipv4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var bound: Int32
        var assigned: UInt16 = 0
        switch address {
        case .ipv4:
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 {
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
                }
                assigned = UInt16(bigEndian: addr.sin_port)
            }
        case .ipv6:
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bound == 0 {
                var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
                _ = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
                }
                assigned = UInt16(bigEndian: addr.sin6_port)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.failed("bind", code)
        }
        if listening, listen(fd, 4) != 0 {
            let code = errno
            close(fd)
            throw SocketError.failed("listen", code)
        }
        openFDs.append(fd)
        return (fd, assigned)
    }

    private func closeSocket(_ fd: Int32) {
        close(fd)
        openFDs.removeAll { $0 == fd }
    }

    /// A port with nothing listening on either family: bind the same port on both, then close both.
    private func freePortOnBothFamilies() throws -> UInt16 {
        for _ in 0..<20 {
            let v4 = try bindSocket(.ipv4, listening: false)
            if let v6 = try? bindSocket(.ipv6, port: v4.port, listening: false) {
                closeSocket(v4.fd)
                closeSocket(v6.fd)
                return v4.port
            }
            closeSocket(v4.fd)
        }
        throw SocketError.failed("no free port on both families", 0)
    }

    // Bug caught: a live IPv4 listener reported dead/unknown.
    func testListeningIPv4BackendIsAlive() async throws {
        let l = try bindSocket(.ipv4, listening: true)
        let result = await LoopbackProbe.probe(.ipv4, port: l.port)
        XCTAssertEqual(result, .alive)
    }

    // Bug caught: ECONNREFUSED mapped to unknown, so a dead route is never flagged.
    func testRefusedConnectionIsDead() async throws {
        let port = try freePortOnBothFamilies()
        let result = await LoopbackProbe.probe(.ipv4, port: port)
        XCTAssertEqual(result, .dead)
    }

    // Bug caught: probing "localhost" only tries IPv4, missing a ::1-only backend and falsely flagging it dead.
    func testLocalhostIsAliveWhenOnlyIPv6Listens() async throws {
        let l = try bindSocket(.ipv6, listening: true)
        let result = await LoopbackProbe.probe(host: "localhost", port: l.port)
        XCTAssertEqual(result, .alive)
    }

    // Bug caught: localhost with an IPv4-only listener reported dead because ::1 refused.
    func testLocalhostIsAliveWhenOnlyIPv4Listens() async throws {
        let l = try bindSocket(.ipv4, listening: true)
        let result = await LoopbackProbe.probe(host: "localhost", port: l.port)
        XCTAssertEqual(result, .alive)
    }

    // Bug caught: localhost with nothing listening not reported dead (route would never be flagged).
    func testLocalhostIsDeadWhenNothingListensOnEitherFamily() async throws {
        let port = try freePortOnBothFamilies()
        let result = await LoopbackProbe.probe(host: "localhost", port: port)
        XCTAssertEqual(result, .dead)
    }

    // Bug caught: 0.0.0.0 target passed to connect() as-is instead of being treated as 127.0.0.1.
    func testWildcardHostProbesIPv4Loopback() async throws {
        let l = try bindSocket(.ipv4, listening: true)
        let result = await LoopbackProbe.probe(host: "0.0.0.0", port: l.port)
        XCTAssertEqual(result, .alive)
    }

    // Bug caught: host "::1" probed over IPv4 instead of IPv6.
    func testIPv6HostProbesIPv6Loopback() async throws {
        let l = try bindSocket(.ipv6, listening: true)
        let result = await LoopbackProbe.probe(host: "::1", port: l.port)
        XCTAssertEqual(result, .alive)
    }

    // Bug caught: a non-loopback host triggers an outbound connection (security) or a verdict other than unknown.
    func testNonLoopbackHostIsUnknownWithoutConnecting() async {
        let start = Date()
        let result = await LoopbackProbe.probe(host: "192.168.1.5", port: 80, timeout: 0.5)
        XCTAssertEqual(result, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }

    // Bug caught: other hostnames resolved via DNS and connected to.
    func testArbitraryHostnameIsUnknownWithoutConnecting() async {
        let start = Date()
        let result = await LoopbackProbe.probe(host: "example.com", port: 80, timeout: 0.5)
        XCTAssertEqual(result, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }

    // Bug caught: port 0 (invalid target) connected and reported dead.
    func testPortZeroIsUnknown() async {
        let direct = await LoopbackProbe.probe(.ipv4, port: 0)
        let viaHost = await LoopbackProbe.probe(host: "127.0.0.1", port: 0)
        XCTAssertEqual(direct, .unknown)
        XCTAssertEqual(viaHost, .unknown)
    }

    // Bug caught: a refused connect waits for the timeout instead of returning immediately.
    func testRefusedProbesReturnQuickly() async throws {
        let ports = try (0..<4).map { _ in try freePortOnBothFamilies() }
        let start = Date()
        let results = await withTaskGroup(of: BackendLiveness.self) { group in
            for port in ports { group.addTask { await LoopbackProbe.probe(host: "localhost", port: port) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results, Array(repeating: .dead, count: 4))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
    }

    // Bug caught: a cancelled evaluation still reports a verdict (dead) that could start a removal timer.
    func testCancelledProbeIsUnknown() async throws {
        let port = try freePortOnBothFamilies()
        let task = Task { () -> BackendLiveness in
            withUnsafeCurrentTask { $0?.cancel() }
            return await LoopbackProbe.probe(.ipv4, port: port)
        }
        let result = await task.value
        XCTAssertEqual(result, .unknown)
    }
}
