import Foundation

/// Fallback scanner using lsof (setuid root) for comprehensive port visibility.
/// Parses machine-readable output from `lsof -iTCP -sTCP:LISTEN -P -n -F pcn`.
public final class LsofScanner: PortScanning, Sendable {

    public init() {}

    public func scan() async -> [PortEntry] {
        let output: String
        do {
            output = try await runLsof()
        } catch {
            return []
        }
        return parseLsofOutput(output)
    }

    private func runLsof() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Parse lsof -F pcn output format:
    /// p<pid>         — process ID
    /// c<command>     — command name
    /// n<name>        — network name (e.g., *:3000, 127.0.0.1:8080)
    func parseLsofOutput(_ output: String) -> [PortEntry] {
        var entries: [PortEntry] = []
        var currentPid: pid_t = 0
        var currentCommand = ""

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let str = String(line)
            guard !str.isEmpty else { continue }

            let prefix = str.first!
            let value = String(str.dropFirst())

            switch prefix {
            case "p":
                currentPid = pid_t(value) ?? 0
            case "c":
                currentCommand = value
            case "n":
                guard currentPid > 0 else { continue }
                if let entry = parseNetworkName(value, pid: currentPid, command: currentCommand) {
                    entries.append(entry)
                }
            default:
                break
            }
        }

        return entries
    }

    private func parseNetworkName(_ name: String, pid: pid_t, command: String) -> PortEntry? {
        // Format: "address:port" or "*:port" or "[::1]:port"
        let parts: (address: String, portStr: String)

        if name.hasPrefix("[") {
            // IPv6: [::1]:port or [::]:port
            guard let closeBracket = name.firstIndex(of: "]") else { return nil }
            let address = String(name[name.index(after: name.startIndex)...name.index(before: closeBracket)])
            let afterBracket = name[name.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":") else { return nil }
            let portStr = String(afterBracket.dropFirst())
            parts = (address, portStr)
        } else {
            // IPv4: addr:port or *:port
            guard let lastColon = name.lastIndex(of: ":") else { return nil }
            let address = String(name[..<lastColon])
            let portStr = String(name[name.index(after: lastColon)...])
            parts = (address, portStr)
        }

        guard let port = UInt16(parts.portStr), port > 0 else { return nil }

        let family: PortEntry.AddressFamily = parts.address.contains(":") ? .ipv6 : .ipv4
        let displayAddress = parts.address == "*" ? "0.0.0.0" : parts.address

        let startTime = LibProc.processStartTime(pid: pid) ?? .distantPast

        return PortEntry(
            pid: pid,
            port: port,
            processName: command,
            executablePath: LibProc.processPath(pid: pid) ?? "",
            protocol: .tcp,
            state: .listen,
            family: family,
            localAddress: displayAddress,
            processStartTime: startTime
        )
    }
}
