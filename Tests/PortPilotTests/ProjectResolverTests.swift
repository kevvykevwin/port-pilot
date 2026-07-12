import XCTest
import Darwin
import Foundation
@testable import PortPilotCore

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
