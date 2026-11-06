import XCTest
import Foundation
import Darwin
@testable import PortPilotCore

final class ManagedLaunchContractTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testEnvironmentPortAndSecretResolution() throws {
        let launch = ManagedLaunch(service: "web", executable: "/usr/bin/true", arguments: [], cwd: "/tmp",
                                   portEnvironment: "PORT", environment: ["MODE": "test"], secretReferences: ["API_KEY": "fixture-key"])
        try launch.validate()
        XCTAssertThrowsError(try launch.resolvedEnvironment(port: 30123, secret: { _ in throw ManagedError.needsDecision }))
        let values = try launch.resolvedEnvironment(port: 30123, secret: { reference in
            XCTAssertEqual(reference, "fixture-key"); return "private-fixture-value"
        })
        XCTAssertEqual(values["PORT"], "30123")
        XCTAssertEqual(values["API_KEY"], "private-fixture-value")
        XCTAssertEqual(values["MODE"], "test")
        var invalid = launch; invalid.arguments = ["{port}"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = launch; invalid.environment = ["PORT": "1"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = launch; invalid.secretReferences = ["BAD=KEY": "fixture-key"]
        XCTAssertThrowsError(try invalid.validate())
        let first = try launch.fingerprint(key: Data("key".utf8), secret: { _ in "one" })
        let second = try launch.fingerprint(key: Data("key".utf8), secret: { _ in "two" })
        XCTAssertNotEqual(first, second)
    }
    func testRecipesAreEncryptedBoundToFingerprintAndSurviveReload() throws {
        let root = try directory(), disk = try ManagedPersistence(root: root)
        let store = ManagedRecipes(persistence: disk, key: Data("fixture-key".utf8))
        let launch = ManagedLaunch(service: "web", executable: "/usr/bin/true", arguments: ["secret-argv-fixture", "{port}"], cwd: "/tmp")
        let fingerprint = try launch.fingerprint(key: Data("fixture-key".utf8))
        try store.save(launch, fingerprint: fingerprint)
        let path = "recipe-\(fingerprint).sealed"
        let bytes = try XCTUnwrap(disk.read(path))
        XCTAssertNil(bytes.range(of: Data("secret-argv-fixture".utf8)))
        let reload = ManagedRecipes(persistence: disk, key: Data("fixture-key".utf8))
        XCTAssertEqual(try reload.load(fingerprint: fingerprint).arguments, launch.arguments)
        XCTAssertThrowsError(try ManagedRecipes(persistence: disk, key: Data("wrong-key".utf8)).load(fingerprint: fingerprint))
        let different = String(repeating: "a", count: 64)
        try disk.write("recipe-\(different).sealed", data: bytes)
        XCTAssertThrowsError(try reload.load(fingerprint: different))
        XCTAssertThrowsError(try reload.load(fingerprint: "../../outside"))
        var corrupt = bytes; corrupt[corrupt.count - 1] ^= 1
        try disk.write(path, data: corrupt)
        XCTAssertThrowsError(try reload.load(fingerprint: fingerprint))
    }
    func testSecretEnrollmentAndBoundedFilesRejectUnsafeInputs() throws {
        let root = try directory(), disk = try ManagedPersistence(root: root)
        let store = ManagedRecipes(persistence: disk, key: Data())
        try disk.write("input", data: Data("fixture-only".utf8))
        try store.enrollSecret("api-key", from: root.appendingPathComponent("input"))
        XCTAssertEqual(try store.secret("api-key"), "fixture-only")
        XCTAssertThrowsError(try store.secret("missing"))
        XCTAssertThrowsError(try store.secret("../input"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.appendingPathComponent("input").path)
        XCTAssertThrowsError(try store.enrollSecret("symlink", from: root.appendingPathComponent("link")))
        XCTAssertThrowsError(try ManagedBoundedFile.read(root.appendingPathComponent("input"), limit: 2))
        chmod(root.appendingPathComponent("input").path, 0o644)
        XCTAssertThrowsError(try store.enrollSecret("public", from: root.appendingPathComponent("input")))
    }
    func testAncestryCapturesNestedChildrenButRejectsReparentingAndPIDReuse() {
        func incarnation(_ pid: Int32) -> ManagedIncarnation {
            ManagedIncarnation(hostId: "host", bootId: "boot", pid: pid, startTime: Date(timeIntervalSince1970: Double(pid)))
        }
        let root = incarnation(10)
        let added = ManagedAncestry.discover(known: [root], pids: [30, 20, 99], relation: { pid in
            (pid == 20 ? 10 : pid == 30 ? 20 : 1, incarnation(pid).startTime)
        }, identity: incarnation)
        XCTAssertEqual(added.map(\.pid), [20, 30])
        var calls = 0
        let orphan = ManagedAncestry.discover(known: [root], pids: [20], relation: { pid in
            calls += 1; return (calls == 1 ? 10 : 1, incarnation(pid).startTime)
        }, identity: incarnation)
        XCTAssertTrue(orphan.isEmpty)
        let reused = ManagedAncestry.discover(known: [root], pids: [20], relation: { _ in (10, Date(timeIntervalSince1970: 19)) }, identity: incarnation)
        XCTAssertTrue(reused.isEmpty)
        let missingParent = ManagedAncestry.discover(known: [root], pids: [20], relation: { _ in (10, incarnation(20).startTime) }, identity: { $0 == 10 ? nil : incarnation($0) })
        XCTAssertTrue(missingParent.isEmpty)
    }
    func testRealChildAncestryUsesKernelIdentity() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["10"]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let parent = try XCTUnwrap(ManagedProcess.incarnation(pid: getpid()))
        let children = ManagedAncestry.discover(known: [parent], pids: [process.processIdentifier])
        XCTAssertEqual(children.map(\.pid), [process.processIdentifier])
        XCTAssertEqual(LibProc.processAncestry(pid: process.processIdentifier)?.parent, getpid())
    }
    func testGitWorktreeMetadataDistinguishesCheckoutsAndWinsOverNestedPackage() throws {
        let root = try directory()
        let common = root.appendingPathComponent("common")
        try FileManager.default.createDirectory(at: common.appendingPathComponent("worktrees/one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: common.appendingPathComponent("worktrees/two"), withIntermediateDirectories: true)
        var identities: [String] = []
        for name in ["one", "two"] {
            let checkout = root.appendingPathComponent(name), package = checkout.appendingPathComponent("packages/web")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: package.appendingPathComponent("package.json"))
            try Data("gitdir: ../common/worktrees/\(name)\n".utf8).write(to: checkout.appendingPathComponent(".git"))
            try Data("../..\n".utf8).write(to: common.appendingPathComponent("worktrees/\(name)/commondir"))
            let launch = ManagedLaunch(service: "web", executable: "/usr/bin/true", arguments: ["{port}"], cwd: package.path)
            let workspace = try launch.workspace()
            XCTAssertEqual(workspace.path, checkout.resolvingSymlinksInPath().path)
            XCTAssertTrue(workspace.filesystemIdentity.contains(":git:"))
            XCTAssertTrue(workspace.filesystemIdentity.contains(":common:"))
            identities.append(workspace.filesystemIdentity)
        }
        XCTAssertNotEqual(identities[0], identities[1])
    }
}
