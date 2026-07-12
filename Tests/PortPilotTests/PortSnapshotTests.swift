import XCTest
@testable import PortPilotCore

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
