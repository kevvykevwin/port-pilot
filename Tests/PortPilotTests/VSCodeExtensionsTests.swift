import XCTest
@testable import PortPilotCore

final class VSCodeExtensionsTests: XCTestCase {

    // MARK: - extractExtensionID

    func testStandardVSCodePath() {
        let path = "/Users/kevin/.vscode/extensions/ms-python.vscode-pylance-2026.1.1/dist/server.bundle.js"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertEqual(result, "ms-python.vscode-pylance")
    }

    func testHyphenatedExtensionID() {
        let path = "/Users/kevin/.vscode/extensions/ms-vscode-remote.remote-ssh-2025.3.1/dist/main.js"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertEqual(result, "ms-vscode-remote.remote-ssh")
    }

    func testCursorPath() {
        let path = "/Users/kevin/.cursor/extensions/github.copilot-1.300.0/dist/extension.js"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertEqual(result, "github.copilot")
    }

    func testVSCodeInsidersPath() {
        let path = "/Users/kevin/.vscode-insiders/extensions/golang.go-0.45.0/out/main.js"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertEqual(result, "golang.go")
    }

    func testNonExtensionPathReturnsNil() {
        let path = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertNil(result)
    }

    func testUnrelatedPathReturnsNil() {
        let path = "/usr/local/bin/node"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertNil(result)
    }

    func testExtensionWithNoVersion() {
        let path = "/Users/kevin/.vscode/extensions/some-publisher.some-ext/dist/main.js"
        let result = VSCodeExtensions.extractExtensionID(from: path)
        XCTAssertEqual(result, "some-publisher.some-ext")
    }

    // MARK: - knownExtensions lookup

    func testKnownExtensionReturnsDescription() {
        let entry = PortEntry(
            pid: 1, port: 4037, processName: "Code Helper (Plugin)",
            executablePath: "/Users/kevin/.vscode/extensions/ms-python.vscode-pylance-2026.1.1/dist/server.js",
            protocol: .tcp, state: .listen, family: .ipv4,
            localAddress: "127.0.0.1", processStartTime: .now
        )
        XCTAssertEqual(entry.vsCodeExtensionDescription, "Python language server (Pylance)")
    }

    func testUnknownExtensionFallsBackToBareID() {
        let entry = PortEntry(
            pid: 1, port: 5000, processName: "Code Helper (Plugin)",
            executablePath: "/Users/kevin/.vscode/extensions/unknown.ext-1.0.0/dist/main.js",
            protocol: .tcp, state: .listen, family: .ipv4,
            localAddress: "127.0.0.1", processStartTime: .now
        )
        XCTAssertEqual(entry.vsCodeExtensionDescription, "unknown.ext")
    }

    func testNonCodeHelperProcessReturnsNil() {
        let entry = PortEntry(
            pid: 1, port: 3000, processName: "node",
            executablePath: "/Users/kevin/.vscode/extensions/ms-python.python-2026.1.0/dist/main.js",
            protocol: .tcp, state: .listen, family: .ipv4,
            localAddress: "127.0.0.1", processStartTime: .now
        )
        XCTAssertNil(entry.vsCodeExtensionDescription)
    }
}
