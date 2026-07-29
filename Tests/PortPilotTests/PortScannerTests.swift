import XCTest
import Darwin
@testable import PortPilotCore

final class PortScannerTests: XCTestCase {

    func testLsofScanFindsSpawnedListener() async throws {
        let listener = try makeListener()
        defer { close(listener.fd) }

        let entries = await LsofScanner().scan()
        let myPid = getpid()

        let found = entries.contains {
            $0.port == listener.port && $0.pid == myPid && $0.state == .listen
        }
        XCTAssertTrue(
            found,
            "Expected lsof to find listening port \(listener.port) for pid \(myPid)"
        )
    }

    func testScanFindsSpawnedListener() async throws {
        let listener = try makeListener()
        defer { close(listener.fd) }

        let entries = await PortScanner().scan()
        let myPid = getpid()

        let found = entries.contains {
            $0.port == listener.port && $0.pid == myPid && $0.state == .listen
        }
        XCTAssertTrue(found, "Expected to find listening port \(listener.port) for pid \(myPid)")
    }

    func testParseLsofOutputHandlesIPv4Listeners() {
        let entries = LsofScanner().parseLsofOutput("""
            p101
            cnode
            n*:3000
            n127.0.0.1:8080
            """)

        XCTAssertEqual(entries.count, 2)
        assertEntry(
            entries[0],
            pid: 101,
            port: 3000,
            command: "node",
            family: .ipv4,
            address: "0.0.0.0"
        )
        assertEntry(
            entries[1],
            pid: 101,
            port: 8080,
            command: "node",
            family: .ipv4,
            address: "127.0.0.1"
        )
    }

    func testParseLsofOutputHandlesIPv6Listeners() {
        let entries = LsofScanner().parseLsofOutput("""
            p202
            cpython
            n[::]:8000
            n[::1]:8001
            """)

        XCTAssertEqual(entries.count, 2)
        assertEntry(
            entries[0],
            pid: 202,
            port: 8000,
            command: "python",
            family: .ipv6,
            address: "::"
        )
        assertEntry(
            entries[1],
            pid: 202,
            port: 8001,
            command: "python",
            family: .ipv6,
            address: "::1"
        )
    }

    func testParseLsofOutputAssociatesCommandsWithPids() {
        let entries = LsofScanner().parseLsofOutput("""
            p303
            cbun
            n127.0.0.1:3001
            p404
            cruby
            n*:4567
            """)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].pid, 303)
        XCTAssertEqual(entries[0].port, 3001)
        XCTAssertEqual(entries[0].processName, "bun")
        XCTAssertEqual(entries[1].pid, 404)
        XCTAssertEqual(entries[1].port, 4567)
        XCTAssertEqual(entries[1].processName, "ruby")
    }

    func testParseLsofOutputSkipsMalformedRecordsAndPortZero() {
        let entries = LsofScanner().parseLsofOutput("""

            n*:1234
            pnot-a-pid
            cbad-pid
            n*:3000
            p505
            cserver
            nmissing-port
            n*:not-a-port
            n*:0
            n[::1]4000
            n127.0.0.1:65536
            xignored
            n127.0.0.1:5000

            """)

        XCTAssertEqual(entries.count, 1)
        assertEntry(
            entries[0],
            pid: 505,
            port: 5000,
            command: "server",
            family: .ipv4,
            address: "127.0.0.1"
        )
    }

    func testSelfTestPasses() async {
        let result = await PortScanner().selfTest()
        XCTAssertTrue(result, "Scanner should see its own process")
    }

    private func makeListener() throws -> (fd: Int32, port: UInt16) {
        let serverFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard serverFD >= 0 else {
            throw ListenerError.socketCreationFailed(errno)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(serverFD)
            throw ListenerError.bindFailed(code)
        }
        guard listen(serverFD, 1) == 0 else {
            let code = errno
            close(serverFD)
            throw ListenerError.listenFailed(code)
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverFD, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            close(serverFD)
            throw ListenerError.socketNameFailed(code)
        }

        return (serverFD, UInt16(bigEndian: boundAddr.sin_port))
    }

    private func assertEntry(
        _ entry: PortEntry,
        pid: pid_t,
        port: UInt16,
        command: String,
        family: PortEntry.AddressFamily,
        address: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(entry.pid, pid, file: file, line: line)
        XCTAssertEqual(entry.port, port, file: file, line: line)
        XCTAssertEqual(entry.processName, command, file: file, line: line)
        XCTAssertEqual(entry.family, family, file: file, line: line)
        XCTAssertEqual(entry.localAddress, address, file: file, line: line)
        XCTAssertEqual(entry.protocol, .tcp, file: file, line: line)
        XCTAssertEqual(entry.state, .listen, file: file, line: line)
    }

    private enum ListenerError: Error {
        case socketCreationFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case socketNameFailed(Int32)
    }
}
