import Foundation

/// Reads `tailscale serve status --json`. Throws when Tailscale is missing,
/// hangs, or returns oversized output.
public protocol ServeStatusReading: Sendable {
    func read() async throws -> Data
}

public struct TailscaleServeReader: ServeStatusReading {
    /// Where the Tailscale app keeps its CLI; it is not on PATH by default.
    public static let cliPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    private let executablePath: String

    public init() { self.init(executablePath: Self.cliPath) }

    init(executablePath: String) { self.executablePath = executablePath }

    /// Bounded like the lsof scan: 5 s timeout, output capped at `ServeConfig.maxBytes`,
    /// and the child is killed on timeout or cancellation.
    public func read() async throws -> Data {
        let output = try await ListenerProcess(
            executablePath: executablePath, arguments: ["serve", "status", "--json"],
            timeout: 5, outputLimit: ServeConfig.maxBytes
        ).run()
        // The runner accepts exit 1 with no output (an lsof quirk). Tailscale prints
        // `{}` when nothing is served, so empty output is a failure too.
        // Anything but a JSON object (empty, text, truncated) is a failed read, so the
        // store keeps its last good routes instead of treating it as "no routes".
        let data = Data(output.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw PortScanError.unavailable
        }
        return data
    }
}

/// Checks whether a loopback backend would accept a connection.
public typealias BackendProbing = @Sendable (_ host: String, _ port: UInt16) async -> BackendLiveness
