import Darwin
import XCTest
@testable import PortPilotCore

final class BoundedScannerTests: XCTestCase {
    func testExplicitSocketFamilyPreservesWildcardIPv6() {
        let entries = LsofScanner().parseLsofOutput("p123\ncnode\nf4\ntIPv6\nn*:3000\nf5\ntIPv4\nn*:3000\n")
        XCTAssertEqual(entries.map(\.family), [.ipv6, .ipv4])
        XCTAssertEqual(entries.map(\.localAddress), ["::", "0.0.0.0"])
        XCTAssertNotEqual(entries[0].id, entries[1].id)
    }

    func testNoMatchingListenersIsHealthyEmpty() async {
        let result = await LsofScanner(executablePath: "/usr/bin/false", arguments: []).scan()
        XCTAssertEqual(result, .success(entries: [], source: .lsof))
    }

    func testLargeOutputIsDrainedBeforeChildExit() async {
        // Exceeds a pipe buffer, but remains below the configured output cap.
        let script = "i=0; while [ $i -lt 5000 ]; do printf 'p123\\ncnode\\nf4\\ntIPv6\\nn*:3000\\n'; i=$((i+1)); done"
        let result = await LsofScanner(executablePath: "/bin/sh", arguments: ["-c", script]).scan()
        guard case .success(let entries, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(entries.count, 5000)
    }

    func testOutputLimitTerminatesOwnedScanner() async {
        let result = await LsofScanner(executablePath: "/usr/bin/yes", arguments: [], outputLimit: 16384).scan()
        XCTAssertEqual(result, .failure(.outputLimitExceeded))
    }

    func testTimeoutTerminatesOwnedScanner() async {
        let start = Date()
        let result = await LsofScanner(executablePath: "/bin/sleep", arguments: ["10"], timeout: 0.05).scan()
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellationDoesNotWaitForTimeout() async throws {
        let task = Task { await LsofScanner(executablePath: "/bin/sleep", arguments: ["10"]).scan() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testEarlyClosedPipesDoNotPreventTimeout() async {
        let result = await LsofScanner(executablePath: "/bin/sh",
            arguments: ["-c", "exec >/dev/null 2>&1; exec /bin/sleep 10"], timeout: 0.05).scan()
        XCTAssertEqual(result, .failure(.timedOut))
    }

    func testTimedOutChildActuallyExits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await LsofScanner(executablePath: "/bin/sh",
            arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "scanner-test", file.path], timeout: 0.2).scan()
        XCTAssertEqual(result, .failure(.timedOut))
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned scanner child is still alive after timeout")
    }

    func testAlreadyCancelledScanDoesNotLaunch() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LsofScanner(executablePath: "/definitely/missing").scan()
        }
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
    }
}
