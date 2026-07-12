import XCTest
import Darwin
@testable import PortPilotCore

final class PortScannerTests: XCTestCase {

    func testLsofScanReturnsResults() async {
        let scanner = LsofScanner()
        let entries = await scanner.scan()
        XCTAssertFalse(entries.isEmpty, "Expected at least one port entry on a live system")
    }

    func testScanFindsSpawnedListener() async throws {
        let serverFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(serverFD, 0, "Failed to create socket")
        defer { close(serverFD) }

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
        XCTAssertEqual(bindResult, 0, "Failed to bind socket")
        XCTAssertEqual(listen(serverFD, 1), 0, "Failed to listen")

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverFD, sockPtr, &addrLen)
            }
        }
        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)

        let scanner = PortScanner()
        let entries = await scanner.scan()
        let myPid = getpid()

        let found = entries.contains { $0.port == assignedPort && $0.pid == myPid && $0.state == .listen }
        XCTAssertTrue(found, "Expected to find listening port \(assignedPort) for pid \(myPid)")
    }

    func testSelfTestPasses() async {
        let scanner = PortScanner()
        let result = await scanner.selfTest()
        XCTAssertTrue(result, "Scanner should see its own process")
    }
}
