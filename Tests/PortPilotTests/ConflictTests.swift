import XCTest
import Darwin
import Foundation
@testable import PortPilotCore

// MARK: - ConflictDetector Tests

final class ConflictDetectorTests: XCTestCase {

    func testNoConflictsWhenUniquePorts() {
        let entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 8080, name: "python"),
        ]
        XCTAssertTrue(ConflictDetector.detect(in: entries).isEmpty)
    }

    func testDetectsConflict() {
        let entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
        ]
        let conflicts = ConflictDetector.detect(in: entries)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].port, 3000)
        XCTAssertEqual(conflicts[0].entries.count, 2)
    }

    func testSamePIDNotConflict() {
        // Same PID on same port (post-dedup shouldn't happen, but detector should not flag it)
        let entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
        ]
        XCTAssertTrue(ConflictDetector.detect(in: entries).isEmpty)
    }

    func testMultipleConflicts() {
        let entries = [
            makeConflictEntry(pid: 1, port: 8080, name: "ruby"),
            makeConflictEntry(pid: 2, port: 8080, name: "python"),
            makeConflictEntry(pid: 3, port: 3000, name: "node"),
            makeConflictEntry(pid: 4, port: 3000, name: "deno"),
        ]
        let conflicts = ConflictDetector.detect(in: entries)
        XCTAssertEqual(conflicts.count, 2)
        XCTAssertEqual(conflicts[0].port, 3000, "Conflicts should be sorted by port ascending")
        XCTAssertEqual(conflicts[1].port, 8080)
    }

    func testEmptyInput() {
        XCTAssertTrue(ConflictDetector.detect(in: []).isEmpty)
    }

    func testConflictLabelMixesProjectAndProcess() {
        var withProject = makeConflictEntry(pid: 1, port: 3000, name: "node")
        withProject.projectPath = "sift-coffee"
        let withoutProject = makeConflictEntry(pid: 2, port: 3000, name: "python")

        let conflict = PortConflict(port: 3000, entries: [withProject, withoutProject])
        XCTAssertEqual(conflict.conflictLabel, "python vs sift-coffee")
    }

    func testConflictLabelDisambiguatesSameNames() {
        let postgres1 = makeConflictEntry(pid: 100, port: 5432, name: "postgres")
        let postgres2 = makeConflictEntry(pid: 200, port: 5432, name: "postgres")

        let conflict = PortConflict(port: 5432, entries: [postgres1, postgres2])
        XCTAssertEqual(conflict.conflictLabel, "postgres (pid 100) vs postgres (pid 200)")
    }
}

// MARK: - PortStore Conflict Property Tests

@MainActor
final class PortStoreConflictTests: XCTestCase {

    func testHasConflicts() {
        let store = PortStore()
        store.entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
        ]
        XCTAssertTrue(store.hasConflicts)
        XCTAssertEqual(store.conflicts.count, 1)
    }

    func testConflictingPortsSet() {
        let store = PortStore()
        store.entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
            makeConflictEntry(pid: 3, port: 8080, name: "ruby"),
        ]
        XCTAssertEqual(store.conflictingPorts, Set([3000]))
    }

    func testNoConflictsNormally() {
        let store = PortStore()
        store.entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 8080, name: "python"),
        ]
        XCTAssertFalse(store.hasConflicts)
        XCTAssertTrue(store.conflictingPorts.isEmpty)
    }
}

// MARK: - PortStore Diff Wiring Tests

@MainActor
final class PortStoreDiffTests: XCTestCase {

    func testFirstRefreshNilDiff() async {
        let scanner = MutableMockScanner(entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
        ])
        let store = PortStore(scanner: scanner)
        await store.refresh()
        XCTAssertNil(store.lastDiff, "First refresh should leave lastDiff nil (no previous snapshot)")
    }

    func testSecondRefreshPopulatesDiff() async {
        let scanner = MutableMockScanner(entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
        ])
        let store = PortStore(scanner: scanner)
        await store.refresh()

        scanner.entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 8080, name: "python"),
        ]
        await store.refresh()

        XCTAssertNotNil(store.lastDiff)
        XCTAssertEqual(store.lastDiff?.added.count, 1)
        XCTAssertEqual(store.lastDiff?.added.first?.port, 8080)
        XCTAssertEqual(store.lastDiff?.removed.count, 0)
    }

    func testConflictResolutionClearsState() async {
        let scanner = MutableMockScanner(entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
        ])
        let store = PortStore(scanner: scanner)
        await store.refresh()
        XCTAssertTrue(store.hasConflicts)

        scanner.entries = [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
        ]
        await store.refresh()
        XCTAssertFalse(store.hasConflicts)
        XCTAssertEqual(store.lastDiff?.removed.count, 1)
    }

    func testOnRefreshCompleteCallback() async {
        let scanner = MutableMockScanner(entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
        ])
        let store = PortStore(scanner: scanner)

        let expectation = XCTestExpectation(description: "callback fires")
        let capturedConflicts = CallbackBox<[PortConflict]>()

        store.onRefreshComplete = { _, conflicts in
            capturedConflicts.value = conflicts
            expectation.fulfill()
        }

        await store.refresh()
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedConflicts.value?.count, 1)
        XCTAssertEqual(capturedConflicts.value?.first?.port, 3000)
    }
}

// MARK: - ConflictNotificationFilter Tests

final class ConflictNotificationFilterTests: XCTestCase {

    func testFirstScanNilDiffNoNotifications() {
        var filter = ConflictNotificationFilter()
        let conflicts = [PortConflict(port: 3000, entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
        ])]

        let result = filter.portsToNotify(diff: nil, conflicts: conflicts)
        XCTAssertTrue(result.isEmpty, "Nil diff (first scan) should not fire any notifications")
    }

    func testNewConflictReturnsPort() {
        var filter = ConflictNotificationFilter()
        let newEntry = makeConflictEntry(pid: 2, port: 3000, name: "python")
        let conflicts = [PortConflict(port: 3000, entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            newEntry,
        ])]
        let diff = SnapshotDiff(added: [newEntry], removed: [])

        let result = filter.portsToNotify(diff: diff, conflicts: conflicts)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].port, 3000)
    }

    func testDebounceWithin30s() {
        var filter = ConflictNotificationFilter()
        let newEntry = makeConflictEntry(pid: 2, port: 3000, name: "python")
        let conflicts = [PortConflict(port: 3000, entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            newEntry,
        ])]
        let diff = SnapshotDiff(added: [newEntry], removed: [])
        let t0 = Date()

        _ = filter.portsToNotify(diff: diff, conflicts: conflicts, now: t0)
        let second = filter.portsToNotify(diff: diff, conflicts: conflicts, now: t0.addingTimeInterval(10))
        XCTAssertTrue(second.isEmpty, "Second notification within debounce window should be suppressed")
    }

    func testDebounceExpires() {
        var filter = ConflictNotificationFilter()
        let newEntry = makeConflictEntry(pid: 2, port: 3000, name: "python")
        let conflicts = [PortConflict(port: 3000, entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            newEntry,
        ])]
        let diff = SnapshotDiff(added: [newEntry], removed: [])
        let t0 = Date()

        _ = filter.portsToNotify(diff: diff, conflicts: conflicts, now: t0)
        let afterWindow = filter.portsToNotify(
            diff: diff,
            conflicts: conflicts,
            now: t0.addingTimeInterval(ConflictNotificationFilter.debounceInterval + 1)
        )
        XCTAssertEqual(afterWindow.count, 1, "After debounce window, same port should fire again")
    }

    func testPrunesResolvedConflicts() {
        var filter = ConflictNotificationFilter()
        let newEntry = makeConflictEntry(pid: 2, port: 3000, name: "python")
        let initialConflicts = [PortConflict(port: 3000, entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            newEntry,
        ])]
        let diff = SnapshotDiff(added: [newEntry], removed: [])

        _ = filter.portsToNotify(diff: diff, conflicts: initialConflicts)
        XCTAssertEqual(filter.lastNotified.count, 1)

        // Conflict resolves — next refresh has no conflicts
        _ = filter.portsToNotify(diff: nil, conflicts: [])
        XCTAssertTrue(filter.lastNotified.isEmpty, "Resolved conflicts should be pruned from debounce state")
    }

    func testNoAddedEntriesNoNotifications() {
        var filter = ConflictNotificationFilter()
        let conflicts = [PortConflict(port: 3000, entries: [
            makeConflictEntry(pid: 1, port: 3000, name: "node"),
            makeConflictEntry(pid: 2, port: 3000, name: "python"),
        ])]
        let diff = SnapshotDiff(added: [], removed: [])

        let result = filter.portsToNotify(diff: diff, conflicts: conflicts)
        XCTAssertTrue(result.isEmpty, "Steady-state (no new entries) should not fire notifications")
    }
}

// MARK: - Helpers

private func makeConflictEntry(
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

private final class MutableMockScanner: PortScanning, @unchecked Sendable {
    var entries: [PortEntry]
    init(entries: [PortEntry] = []) { self.entries = entries }
    func scan() async -> [PortEntry] { entries }
}

/// Thread-safe box for capturing values from async callbacks in tests.
private final class CallbackBox<T>: @unchecked Sendable {
    var value: T?
}
