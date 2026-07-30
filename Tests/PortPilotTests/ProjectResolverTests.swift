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

    func testFindProjectRootRecognizesGitDirectoryFromNestedPath() throws {
        let fixture = try makeTemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let project = fixture.appendingPathComponent("normal-project")
        let nested = project.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(
            ProjectResolver().findProjectRoot(from: nested.path),
            project.standardizedFileURL.path
        )
    }

    func testFindProjectRootRecognizesWorktreeGitFileFromNestedPath() throws {
        let fixture = try makeTemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let project = fixture.appendingPathComponent("worktree-project")
        let nested = project.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let gitFile = project.appendingPathComponent(".git")
        try Data("gitdir: /tmp/example\n".utf8).write(to: gitFile)

        XCTAssertEqual(
            ProjectResolver().findProjectRoot(from: nested.path),
            project.standardizedFileURL.path
        )
    }

    func testFindProjectRootReturnsNilWithoutProjectMarkers() throws {
        let fixture = try makeTemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let nested = fixture.appendingPathComponent("plain-directory/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertNil(ProjectResolver().findProjectRoot(from: nested.path))
    }

    func testProjectDisplayNamesAddOnlyRequiredParentContext() {
        let labels = ProjectDisplayName.labels(for: [
            "/tmp/client-a/app",
            "/tmp/client-b/app",
            "/tmp/standalone/api",
        ])

        XCTAssertEqual(labels["/tmp/client-a/app"], "client-a/app")
        XCTAssertEqual(labels["/tmp/client-b/app"], "client-b/app")
        XCTAssertEqual(labels["/tmp/standalone/api"], "api")
    }

    private func makeTemporaryFixture() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("portpilot-project-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        return fixture
    }
}
