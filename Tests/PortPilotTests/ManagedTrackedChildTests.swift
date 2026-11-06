import XCTest
import Foundation
@testable import PortPilotCore

final class ManagedTrackedChildTests: XCTestCase, @unchecked Sendable {
    private func child(code: String) throws -> (ManagedTrackedChild, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pp-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let launch = ManagedLaunch(service: "fixture", executable: "/usr/bin/python3", arguments: ["-c", code, "{port}"], cwd: directory.path)
        let child = try ManagedTrackedChild(launch: launch, port: 30001, environment: [:])
        addTeardownBlock {
            _ = ProcessKiller.forceKill(pid: child.identity.pid, expectedStartTime: child.identity.startTime)
            for _ in 0..<100 {
                _ = child.treeVerified()
                if ManagedProcess.incarnation(pid: child.identity.pid) != child.identity { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        return (child, directory)
    }
    func testChildCannotExecuteBeforeIdentityAndForkWatchAreRecorded() async throws {
        let (child, root) = try child(code: "import pathlib,time; pathlib.Path('ran').write_text('yes'); time.sleep(30)")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran").path))
        XCTAssertTrue(child.treeVerified())
        try child.resume()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("ran").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran").path))
        XCTAssertTrue(child.treeVerified())
        XCTAssertThrowsError(try child.resume())
    }
    func testEvenAnAlreadyExitedChildPermanentlyInvalidatesTreeProof() async throws {
        let (child, root) = try child(code: """
        import os,pathlib,time
        pid = os.fork()
        if pid == 0: os._exit(0)
        os.waitpid(pid, 0)
        pathlib.Path('forked').write_text('yes')
        time.sleep(30)
        """)
        try child.resume()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("forked").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("forked").path))
        XCTAssertFalse(child.treeVerified())
        XCTAssertFalse(child.treeVerified(), "Consuming the event cannot restore completeness")
    }
}
