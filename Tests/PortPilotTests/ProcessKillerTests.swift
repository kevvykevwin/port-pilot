import XCTest
import Foundation
@testable import PortPilotCore

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
