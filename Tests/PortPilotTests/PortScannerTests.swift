import XCTest
import Darwin
import Foundation
@testable import PortPilotCore

// MARK: - Scanner Tests

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

// MARK: - Snapshot Tests

final class PortSnapshotTests: XCTestCase {

    func testDiffDetectsAdded() {
        let entry1 = makeEntry(pid: 1, port: 3000, name: "node")
        let entry2 = makeEntry(pid: 2, port: 8080, name: "python")

        let prev = PortSnapshot(entries: [entry1])
        let curr = PortSnapshot(entries: [entry1, entry2])
        let diff = curr.diff(from: prev)

        XCTAssertEqual(diff.added.count, 1)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.added[0].port, 8080)
    }

    func testDiffDetectsRemoved() {
        let entry1 = makeEntry(pid: 1, port: 3000, name: "node")
        let entry2 = makeEntry(pid: 2, port: 8080, name: "python")

        let prev = PortSnapshot(entries: [entry1, entry2])
        let curr = PortSnapshot(entries: [entry1])
        let diff = curr.diff(from: prev)

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.removed[0].port, 8080)
    }
}

// MARK: - ProjectResolver Tests

final class ProjectResolverTests: XCTestCase {

    func testResolverDoesNotCrash() {
        let resolver = ProjectResolver()
        let result = resolver.resolve(pid: getpid(), startTime: Date())
        // May be nil if cwd isn't in a project — that's valid
        _ = result as String?
    }

    func testResolverCacheRespectsPidStartTime() {
        let resolver = ProjectResolver()
        let myPid = getpid()
        let startTime = Date()

        let result1 = resolver.resolve(pid: myPid, startTime: startTime)
        let result2 = resolver.resolve(pid: myPid, startTime: startTime)
        XCTAssertEqual(result1, result2, "Cache hit should return same value")

        // Different startTime = cache miss (should not crash)
        let result3 = resolver.resolve(pid: myPid, startTime: startTime.addingTimeInterval(-100))
        _ = result3 as String?
    }

    func testGitMarkerDirectorySetup() throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("portpilot-test-\(Int.random(in: 1_000_000...9_999_999))")
        let gitDir = tmpBase.appendingPathComponent("my-project/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}

// MARK: - PortStore Tests

@MainActor
final class PortStoreTests: XCTestCase {

    func testSearchFilterByPort() {
        let store = PortStore()
        store.entries = [
            makeEntry(pid: 1, port: 3000, name: "node"),
            makeEntry(pid: 2, port: 8080, name: "python"),
            makeEntry(pid: 3, port: 5432, name: "postgres"),
        ]
        store.searchText = "8080"

        XCTAssertEqual(store.filteredEntries.count, 1)
        XCTAssertEqual(store.filteredEntries[0].port, 8080)
    }

    func testSearchFilterByProcessName() {
        let store = PortStore()
        store.entries = [
            makeEntry(pid: 1, port: 3000, name: "node"),
            makeEntry(pid: 2, port: 8080, name: "python"),
        ]
        store.searchText = "python"

        XCTAssertEqual(store.filteredEntries.count, 1)
        XCTAssertEqual(store.filteredEntries[0].processName, "python")
    }

    func testEmptySearchReturnsAll() {
        let store = PortStore()
        store.entries = [
            makeEntry(pid: 1, port: 3000, name: "node"),
            makeEntry(pid: 2, port: 8080, name: "python"),
        ]
        store.searchText = ""

        XCTAssertEqual(store.filteredEntries.count, 2)
    }

    func testGroupByProject() {
        let store = PortStore()
        var e1 = makeEntry(pid: 1, port: 3000, name: "node")
        e1.projectPath = "sift-coffee"
        var e2 = makeEntry(pid: 2, port: 3001, name: "next")
        e2.projectPath = "sift-coffee"
        var e3 = makeEntry(pid: 3, port: 8080, name: "python")
        e3.projectPath = "portpilot"

        store.entries = [e1, e2, e3]
        store.groupMode = .project

        let groups = store.grouped
        XCTAssertEqual(groups.count, 2)

        let ppGroup = groups.first { $0.name == "portpilot" }
        let scGroup = groups.first { $0.name == "sift-coffee" }
        XCTAssertEqual(ppGroup?.entries.count, 1)
        XCTAssertEqual(scGroup?.entries.count, 2)
    }

    func testGroupByPortRange() {
        let store = PortStore()
        store.entries = [
            makeEntry(pid: 1, port: 80, name: "nginx"),
            makeEntry(pid: 2, port: 5432, name: "postgres"),
            makeEntry(pid: 3, port: 3000, name: "node"),
            makeEntry(pid: 4, port: 12000, name: "custom"),
        ]
        store.groupMode = .type

        let groupNames = store.grouped.map(\.name)
        XCTAssertTrue(groupNames.contains("System (1-1023)"))
        XCTAssertTrue(groupNames.contains("Databases"))
        XCTAssertTrue(groupNames.contains("Dev Servers (3000-9999)"))
        XCTAssertTrue(groupNames.contains("High Ports (10000+)"))
    }

    func testIPv6Dedup() async {
        let mockScanner = MockScanner(entries: [
            makeEntry(pid: 10, port: 4000, name: "server", family: .ipv6),
            makeEntry(pid: 10, port: 4000, name: "server", family: .ipv4),
            makeEntry(pid: 11, port: 5000, name: "other", family: .ipv4),
        ])
        let store = PortStore(scanner: mockScanner)
        await store.refresh()

        XCTAssertEqual(store.entries.count, 2)
        let port4000 = store.entries.first { $0.port == 4000 }
        XCTAssertEqual(port4000?.family, .ipv4, "IPv4 should be preferred in dedup")
    }
}

// MARK: - ProcessKiller Tests

final class ProcessKillerTests: XCTestCase {

    func testKillSpawnedProcess() async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["999"]
        try task.run()
        let childPid = task.processIdentifier

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(ProcessKiller.isRunning(pid: childPid))

        let result = await ProcessKiller.terminateWithGrace(pid: childPid, graceSeconds: 2.0)

        switch result {
        case .terminated, .processGone:
            break
        case .forceKillNeeded:
            _ = ProcessKiller.forceKill(pid: childPid)
            XCTFail("Process did not exit after SIGTERM grace period")
        case .permissionDenied:
            XCTFail("SIGTERM permission denied")
        case .failed(let msg):
            XCTFail("Kill failed: \(msg)")
        }

        XCTAssertFalse(ProcessKiller.isRunning(pid: childPid))
    }
}

// MARK: - Helpers

private func makeEntry(
    pid: pid_t, port: UInt16, name: String,
    family: PortEntry.AddressFamily = .ipv4
) -> PortEntry {
    PortEntry(
        pid: pid, port: port, processName: name,
        executablePath: "/usr/bin/\(name)", protocol: .tcp,
        state: .listen, family: family,
        localAddress: family == .ipv4 ? "127.0.0.1" : "::1",
        processStartTime: .now
    )
}

private struct MockScanner: PortScanning {
    let entries: [PortEntry]
    func scan() async -> [PortEntry] { entries }
}
