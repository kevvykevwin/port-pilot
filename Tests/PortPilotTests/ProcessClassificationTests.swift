import Foundation
import XCTest
@testable import PortPilotCore

final class ProcessClassificationTests: XCTestCase {
    func testPortsNeverOverrideKnownIdentity() {
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 5432, name: "node")), .devServers)
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 3000, name: "postgres")), .databases)
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 1355, name: "custom")), .unknown)
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 80, name: "custom")), .unknown)
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 50000, name: "custom")), .unknown)
    }

    func testInfrastructureAndEditorEvidence() {
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 8317, name: "cliproxyapi")), .infrastructure)
        XCTAssertEqual(PortCategory.categorize(makeEntry(pid: 1, port: 55555, name: "cloudflared")), .infrastructure)
        let tailscale = makeEntry(pid: 1, port: 55145, name: "IPNExtension",
                                 executablePath: "/Applications/Tailscale.app/Contents/PlugIns/IPNExtension.appex/Contents/MacOS/IPNExtension")
        XCTAssertEqual(ProcessClassifier.classify(tailscale).ownership, .app)
        XCTAssertEqual(PortCategory.categorize(tailscale), .infrastructure)
        let portless = makeEntry(pid: 1, port: 1356, name: "node",
                                scriptPath: "/opt/homebrew/lib/node_modules/portless/dist/cli.js")
        XCTAssertEqual(PortCategory.categorize(portless), .infrastructure)
        let editor = makeEntry(pid: 1, port: 60000, name: "node",
                              scriptPath: "/Users/test/.vscode/extensions/ms-python.vscode-pylance-2026.1.1/server.js")
        XCTAssertEqual(PortCategory.categorize(editor), .editorServices)
    }

    func testNameAloneDoesNotOverrideExecutable() {
        let entry = makeEntry(pid: 1, port: 5432, name: "postgres", executablePath: "/opt/tools/custom")
        XCTAssertEqual(PortCategory.categorize(entry), .unknown)
        let missing = makeEntry(pid: 1, port: 5432, name: "postgres", executablePath: "")
        XCTAssertEqual(PortCategory.categorize(missing), .unknown)
    }

    func testRuntimeOverrideRequiresContextAndIsProjectScoped() {
        var entry = makeEntry(pid: 1, port: 3000, name: "node")
        XCTAssertNil(ProcessClassifier.overrideKey(for: entry))
        entry.projectPath = "/projects/a"
        let first = ProcessClassifier.overrideKey(for: entry)
        entry.projectPath = "/projects/b"
        XCTAssertNotEqual(first, ProcessClassifier.overrideKey(for: entry))
    }

    func testScriptExtractionNeverInterpretsEvalOrSwitchValuesAsScripts() {
        XCTAssertEqual(LibProc.scriptPath(arguments: ["node", "server.js", "secret"], cwd: "/projects/a"), "/projects/a/server.js")
        XCTAssertNil(LibProc.scriptPath(arguments: ["node", "-e", "secret.js"], cwd: "/projects/a"))
        XCTAssertNil(LibProc.scriptPath(arguments: ["node", "--require", "setup.js", "main.js"], cwd: "/projects/a"))
        XCTAssertNil(LibProc.scriptPath(arguments: ["python", "-m", "http.server"], cwd: "/projects/a"))
    }
}

@MainActor
final class ProcessPreferenceTests: XCTestCase {
    private func projectEntry(pid: pid_t, port: UInt16, name: String = "node") -> PortEntry {
        var entry = makeEntry(pid: pid, port: port, name: name)
        entry.projectPath = "/projects/a"
        return entry
    }

    func testSavedOverrideSurvivesRestartAndCanBeReset() throws {
        let suite = "PortPilot.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = projectEntry(pid: 1, port: 3000)
        let first = PortStore(defaults: defaults)
        first.setCategory(.infrastructure, for: entry)
        let second = PortStore(defaults: defaults)
        XCTAssertEqual(second.classification(for: entry).category, .infrastructure)
        XCTAssertTrue(second.classification(for: entry).isOverride)
        XCTAssertNil(second.projectOwner(for: entry))
        var other = entry
        other.projectPath = "/projects/b"
        XCTAssertEqual(second.classification(for: other).category, .devServers)
        second.setCategory(nil, for: entry)
        XCTAssertEqual(PortStore(defaults: defaults).classification(for: entry).category, .devServers)
    }

    func testExpectedServicesAllowRestartsButDetectNewAndDuplicateServices() {
        let store = PortStore()
        store.entries = [projectEntry(pid: 1, port: 3000), projectEntry(pid: 2, port: 8000, name: "python")]
        XCTAssertTrue(store.hasMultiPortProjects)
        store.rememberExpectedServices(for: "/projects/a")
        XCTAssertFalse(store.hasMultiPortProjects)
        store.entries = [projectEntry(pid: 3, port: 3000), projectEntry(pid: 4, port: 8000, name: "python")]
        XCTAssertFalse(store.hasMultiPortProjects, "Restarted processes are still expected")
        store.entries.append(projectEntry(pid: 5, port: 3000))
        XCTAssertTrue(store.hasMultiPortProjects, "Duplicate service must not be hidden by a baseline")
        store.entries = [projectEntry(pid: 6, port: 3000, name: "bun")]
        XCTAssertTrue(store.hasMultiPortProjects, "Different executable on an expected port still needs review")
        store.entries = [projectEntry(pid: 3, port: 3000)]
        XCTAssertFalse(store.hasMultiPortProjects, "Missing services are not duplicates")
        store.clearExpectedServices(for: "/projects/a")
        XCTAssertFalse(store.hasExpectedServices(for: "/projects/a"))
    }

    func testExpectedServicesArePersistentAndScopedToFullRoot() throws {
        let suite = "PortPilot.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PortStore(defaults: defaults)
        store.entries = [projectEntry(pid: 1, port: 3000), projectEntry(pid: 2, port: 8000)]
        store.rememberExpectedServices(for: "/projects/a")
        let restored = PortStore(defaults: defaults)
        restored.entries = store.entries
        XCTAssertFalse(restored.hasMultiPortProjects)
        restored.entries[0].projectPath = "/other/a"
        restored.entries[1].projectPath = "/other/a"
        XCTAssertTrue(restored.hasMultiPortProjects)
    }

    func testMalformedPreferencesFallBackToAutomaticClassification() throws {
        let suite = "PortPilot.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: ProcessPreferences.storageKey)
        let store = PortStore(defaults: defaults)
        XCTAssertEqual(store.classification(for: projectEntry(pid: 1, port: 3000)).category, .devServers)
    }
}
