import XCTest
@testable import PortPilotCore

@MainActor
final class BindingIdentityTests: XCTestCase {
    func testDedupForDisplayCannotHideIPv6Overlap() async {
        let ipv4 = makeEntry(pid: 1, port: 3000, name: "node", family: .ipv4)
        let ipv6 = makeEntry(pid: 1, port: 3000, name: "node", family: .ipv6, address: "::")
        let overlapping = makeEntry(pid: 2, port: 3000, name: "node", family: .ipv6)
        let unrelated = makeEntry(pid: 3, port: 3000, name: "node", family: .ipv4, address: "192.0.2.1")
        let store = PortStore(scanner: MockScanner(entries: [ipv4, ipv6, overlapping, unrelated, ipv4]))
        await store.refresh()
        XCTAssertEqual(store.entries.count, 4)
        XCTAssertEqual(store.displayEntries.count, 3)
        XCTAssertEqual(store.conflictingRowIDs, Set([ipv6.rowID, overlapping.rowID]))
        XCTAssertFalse(store.conflictingRowIDs.contains(unrelated.rowID))
        XCTAssertTrue(store.bindingSummary(for: ipv4).contains("::"))
    }

    func testSameFamilyDistinctAddressesArePreserved() async {
        let a = makeEntry(pid: 1, port: 3000, name: "node", address: "127.0.0.1")
        let b = makeEntry(pid: 1, port: 3000, name: "node", address: "192.0.2.1")
        let c = makeEntry(pid: 2, port: 3000, name: "node", address: "192.0.2.1")
        let store = PortStore(scanner: MockScanner(entries: [a, b, c]))
        await store.refresh()
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.displayEntries.count, 2)
        XCTAssertEqual(store.conflicts.first?.entries.count, 2)
    }

    func testPIDReuseChangesRowAndSnapshotIdentity() {
        let before = makeEntry(pid: 1, port: 3000, name: "node", startTime: Date(timeIntervalSince1970: 1))
        let after = makeEntry(pid: 1, port: 3000, name: "node", startTime: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(before.rowID, after.rowID)
        let diff = PortSnapshot(entries: [after]).diff(from: PortSnapshot(entries: [before]))
        XCTAssertEqual(diff.added, [after])
        XCTAssertEqual(diff.removed, [before])
    }

    func testFreshnessAndSourceSurviveFailedScan() async {
        let scanner = ControlledScanner()
        let store = PortStore(scanner: scanner)
        let first = Task { await store.refresh() }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(0, with: .success(entries: [], source: .libprocFallback))
        await first.value
        let time = store.lastSuccessfulScan
        XCTAssertNotNil(time)
        XCTAssertNotNil(store.lastScanDuration)
        let second = Task { await store.refresh() }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(1, with: .failure(.allScannersFailed))
        await second.value
        XCTAssertEqual(store.lastSuccessfulScan, time)
        XCTAssertEqual(store.lastScanSource, .libprocFallback)
        XCTAssertNotNil(store.scanError)
    }
}
