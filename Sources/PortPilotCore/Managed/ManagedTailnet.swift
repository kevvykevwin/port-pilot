import Foundation
import Darwin

public struct ManagedTailnetRoute: Codable, Sendable, Equatable {
    public var selector: String
    public var endpoint: String
    public var stablePort: UInt16
    public var fingerprint: String
    public var verified: Bool
    public var observedAt: Date
}

/// Only `serve status --json` is executable through this adapter. Provisioning
/// and removal are deliberately absent; enrollment adopts an existing selector.
public enum ManagedTailnet {
    public static func inspect(_ data: Data, selector: String, stablePort: UInt16, now: Date = Date()) throws -> ManagedTailnetRoute {
        guard data.count <= 1_048_576, stablePort >= 20000, stablePort <= 20999,
              let colon = selector.lastIndex(of: ":"),
              let port = UInt16(selector[selector.index(after: colon)...]), port > 0 else { throw ManagedError.invalidInput }
        let host = String(selector[..<colon])
        guard !host.isEmpty, host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !host.hasPrefix("."), !host.hasSuffix(".") else { throw ManagedError.invalidInput }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tcp = root["TCP"] as? [String: Any], let transport = tcp[String(port)] as? [String: Any], transport["HTTPS"] as? Bool == true,
              let web = root["Web"] as? [String: Any], let route = web[selector] as? [String: Any],
              let handlers = route["Handlers"] as? [String: Any], handlers.count == 1,
              let handler = handlers["/"] as? [String: Any], handler.count == 1,
              let proxy = handler["Proxy"] as? String,
              proxy == "http://127.0.0.1:\(stablePort)",
              (root["AllowFunnel"] as? [String: Bool])?[selector] != true else { throw ManagedError.needsDecision }
        // Only the owned selector participates: unrelated configuration changes
        // neither overwrite routes nor invalidate this enrollment.
        let normalized = try JSONSerialization.data(withJSONObject: ["TCP": transport, "Web": route, "Funnel": false], options: [.sortedKeys])
        return ManagedTailnetRoute(selector: selector, endpoint: "https://\(selector)", stablePort: stablePort,
                                   fingerprint: ManagedDigest.hash(normalized), verified: true, observedAt: now)
    }
    public static func readStatus(executable: String = "/Applications/Tailscale.app/Contents/MacOS/Tailscale") async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["serve", "status", "--json"]
            process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.standardOutput = output
            do { try process.run() } catch { throw ManagedError.dependencyUnavailable }
            let identity = ManagedProcess.incarnation(pid: process.processIdentifier)
            defer {
                try? output.fileHandleForReading.close()
                if process.isRunning, let identity, ManagedProcess.incarnation(pid: identity.pid) == identity {
                    _ = ProcessKiller.forceKill(pid: identity.pid, expectedStartTime: identity.startTime)
                }
            }
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            while ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard bytes.count + count <= 1_048_576 else { throw ManagedError.recordTooLarge }
                    bytes.append(contentsOf: buffer.prefix(count)); continue
                }
                if count == 0 && !process.isRunning {
                    guard process.terminationStatus == 0 else { throw ManagedError.dependencyUnavailable }
                    return bytes
                }
                if count < 0 && errno != EINTR && errno != EAGAIN { throw ManagedError.dependencyUnavailable }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
            throw ManagedError.dependencyUnavailable
        }.value
    }
}
