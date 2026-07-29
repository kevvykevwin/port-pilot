import XCTest
@testable import PortPilotCore

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

    func testWhitespaceSearchReturnsAll() {
        let store = PortStore()
        store.entries = [
            makeEntry(pid: 1, port: 3000, name: "node"),
            makeEntry(pid: 2, port: 8080, name: "python"),
        ]
        store.searchText = " \n\t "

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

    /// Regression: VS Code "Code Helper (Plugin)" language servers (e.g. Pylance)
    /// run with cwd inside the extension dir, which the resolver used to surface as
    /// a phantom project named "ms-python.vscode-pylance-2026.2.1". Editor helpers
    /// must group under macOS Apps regardless of any resolved projectPath.
    func testEditorHelperGroupsUnderMacAppsNotAsProject() {
        let store = PortStore()
        var pylance = makeEntry(
            pid: 1, port: 49861, name: "Code Helper (Plugin)",
            executablePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        )
        pylance.projectPath = "ms-python.vscode-pylance-2026.2.1"  // the phantom the bug produced
        var realServer = makeEntry(pid: 2, port: 3000, name: "node")
        realServer.projectPath = "sift-coffee"

        store.entries = [pylance, realServer]
        store.groupMode = .project

        let groups = store.grouped
        XCTAssertNil(
            groups.first { $0.name == "ms-python.vscode-pylance-2026.2.1" },
            "Editor helper must not appear as its own project"
        )
        XCTAssertNil(
            groups.first { $0.name == "Other" },
            "Editor helper must not fall through to the Other bucket"
        )
        XCTAssertEqual(groups.first { $0.name == "macOS Apps" }?.entries.count, 1)
        XCTAssertEqual(groups.first { $0.name == "sift-coffee" }?.entries.count, 1)
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
        XCTAssertTrue(groupNames.contains("System"), "got: \(groupNames)")
        XCTAssertTrue(groupNames.contains("Databases"), "got: \(groupNames)")
        XCTAssertTrue(groupNames.contains("Dev Servers"), "got: \(groupNames)")
        XCTAssertTrue(groupNames.contains("High Ports"), "got: \(groupNames)")
    }

    func testMultiPortProjectsCountsOnlyListeningEntries() {
        let store = PortStore()
        var listening = makeEntry(pid: 1, port: 3000, name: "node", state: .listen)
        listening.projectPath = "sift-coffee"
        var established = makeEntry(pid: 2, port: 3001, name: "node", state: .established)
        established.projectPath = "sift-coffee"
        var otherProjectPort = makeEntry(pid: 3, port: 5173, name: "vite", state: .listen)
        otherProjectPort.projectPath = "portpilot"

        store.entries = [listening, established, otherProjectPort]

        XCTAssertFalse(store.hasMultiPortProjects)
        XCTAssertTrue(store.multiPortProjects.isEmpty)
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

    func testStaleRefreshCompletingFirstCannotPublish() async {
        let scanner = ControlledScanner()
        let store = PortStore(scanner: scanner)
        var callbackPorts: [[UInt16]] = []
        store.onRefreshComplete = { _, _ in
            callbackPorts.append(store.entries.map(\.port))
        }

        let firstRefresh = Task { await store.refresh() }
        await scanner.waitForRequestCount(1)
        let secondRefresh = Task { await store.refresh() }
        await scanner.waitForRequestCount(2)

        await scanner.completeRequest(
            0,
            with: [makeEntry(pid: 1, port: 3000, name: "stale")]
        )
        await firstRefresh.value

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.lastDiff)
        XCTAssertTrue(store.isScanning, "Newest refresh is still in flight")
        XCTAssertTrue(callbackPorts.isEmpty)

        await scanner.completeRequest(
            1,
            with: [makeEntry(pid: 2, port: 4000, name: "newest")]
        )
        await secondRefresh.value

        XCTAssertEqual(store.entries.map(\.port), [4000])
        XCTAssertNil(store.lastDiff)
        XCTAssertFalse(store.isScanning)
        XCTAssertEqual(callbackPorts, [[4000]])
    }

    func testNewestRefreshCompletingFirstRemainsPublished() async {
        let scanner = ControlledScanner()
        let store = PortStore(scanner: scanner)
        var callbackPorts: [[UInt16]] = []
        store.onRefreshComplete = { _, _ in
            callbackPorts.append(store.entries.map(\.port))
        }

        let firstRefresh = Task { await store.refresh() }
        await scanner.waitForRequestCount(1)
        let secondRefresh = Task { await store.refresh() }
        await scanner.waitForRequestCount(2)

        await scanner.completeRequest(
            1,
            with: [makeEntry(pid: 2, port: 4000, name: "newest")]
        )
        await secondRefresh.value

        XCTAssertEqual(store.entries.map(\.port), [4000])
        XCTAssertNil(store.lastDiff)
        XCTAssertFalse(store.isScanning)
        XCTAssertEqual(callbackPorts, [[4000]])

        await scanner.completeRequest(
            0,
            with: [makeEntry(pid: 1, port: 3000, name: "stale")]
        )
        await firstRefresh.value

        XCTAssertEqual(store.entries.map(\.port), [4000])
        XCTAssertNil(store.lastDiff)
        XCTAssertFalse(store.isScanning)
        XCTAssertEqual(callbackPorts, [[4000]])

        let thirdRefresh = Task { await store.refresh() }
        await scanner.waitForRequestCount(3)
        await scanner.completeRequest(
            2,
            with: [makeEntry(pid: 3, port: 5000, name: "next")]
        )
        await thirdRefresh.value

        XCTAssertEqual(store.entries.map(\.port), [5000])
        XCTAssertEqual(store.lastDiff?.added.map(\.port), [5000])
        XCTAssertEqual(store.lastDiff?.removed.map(\.port), [4000])
        XCTAssertEqual(callbackPorts, [[4000], [5000]])
    }
}
