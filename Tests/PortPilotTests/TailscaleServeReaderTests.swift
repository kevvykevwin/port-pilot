import XCTest
@testable import PortPilotCore

/// The reader runs an external CLI on a timer, so a hang, flood or silent
/// failure must surface as an error (keeping the last good config), never as routes.
final class TailscaleServeReaderTests: XCTestCase {
    private func script(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// Catches the reader dropping or reordering the `serve status --json` arguments.
    func testPassesServeStatusJSONArguments() async throws {
        let path = try script(#"[ "$*" = "serve status --json" ] && echo '{"TCP":{}}' || echo 'wrong args'"#)
        let data = try await TailscaleServeReader(executablePath: path).read()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"TCP\":{}}\n")
    }

    /// Catches empty output being read as "no routes", which would clear every finding.
    func testEmptyOutputWithExitOneIsAnError() async throws {
        let path = try script("exit 1")
        do { _ = try await TailscaleServeReader(executablePath: path).read(); XCTFail("expected error") }
        catch {}
    }

    /// Catches non-JSON output with exit 0 (a warning, truncated output) wiping the last good routes.
    func testNonJSONOutputIsAnError() async throws {
        for body in ["echo 'not json'", "echo '[]'", #"printf '{"TCP":'"#] {
            let path = try script(body)
            do { _ = try await TailscaleServeReader(executablePath: path).read(); XCTFail("expected error for \(body)") }
            catch {}
        }
    }

    /// Tailscale prints `{}` when nothing is served; that is a valid read, not an error.
    func testEmptyObjectIsAValidRead() async throws {
        let path = try script("echo '{}'")
        let data = try await TailscaleServeReader(executablePath: path).read()
        XCTAssertEqual(ServeConfig.parse(data), [])
    }

    /// Catches a missing Tailscale install crashing or returning data.
    func testMissingCLIThrows() async {
        do { _ = try await TailscaleServeReader(executablePath: "/nonexistent/tailscale").read(); XCTFail("expected error") }
        catch {}
    }

    /// Catches the output cap being lost: a flood must stop at ServeConfig.maxBytes.
    func testOversizedOutputThrows() async throws {
        let path = try script("exec /usr/bin/yes")
        do { _ = try await TailscaleServeReader(executablePath: path).read(); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? PortScanError, .outputLimitExceeded) }
    }
}
