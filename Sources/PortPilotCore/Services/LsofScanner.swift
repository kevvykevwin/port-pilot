import Foundation

/// Primary scanner using lsof for the TCP listeners visible to the current user.
/// Parses machine-readable output from `lsof -iTCP -sTCP:LISTEN -P -n -F pcftn`.
public final class LsofScanner: PortScanning, Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let outputLimit: Int

    public convenience init() { self.init(executablePath: "/usr/sbin/lsof") }

    init(executablePath: String, arguments: [String] = ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcftn"],
         timeout: TimeInterval = 5, outputLimit: Int = 4 * 1024 * 1024) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func scan() async -> PortScanResult {
        do {
            let output = try await ListenerProcess(
                executablePath: executablePath, arguments: arguments,
                timeout: timeout, outputLimit: outputLimit
            ).run()
            guard !Task.isCancelled else { return .failure(.cancelled) }
            return .success(entries: parseLsofOutput(output), source: .lsof)
        } catch let error as PortScanError {
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }
    }

    /// Parse lsof -F pcftn output format:
    /// p<pid>         — process ID
    /// c<command>     — command name
    /// n<name>        — network name (e.g., *:3000, 127.0.0.1:8080)
    func parseLsofOutput(_ output: String) -> [PortEntry] {
        var entries: [PortEntry] = []
        var currentPid: pid_t = 0
        var currentCommand = ""
        var currentFamily: PortEntry.AddressFamily?
        var metadata: [pid_t: (Date, String, String?)] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let str = String(line)
            let prefix = str.first!
            let value = String(str.dropFirst())

            switch prefix {
            case "p":
                currentPid = pid_t(value) ?? 0
                currentFamily = nil
                currentCommand = ""
            case "c":
                currentCommand = value
            case "f":
                currentFamily = nil
            case "t":
                currentFamily = value == "IPv6" ? .ipv6 : value == "IPv4" ? .ipv4 : nil
            case "n":
                guard currentPid > 0 else { continue }
                if metadata[currentPid] == nil {
                    metadata[currentPid] = (
                        LibProc.processStartTime(pid: currentPid) ?? .distantPast,
                        LibProc.processPath(pid: currentPid) ?? "",
                        LibProc.processScriptPath(pid: currentPid)
                    )
                }
                if let entry = parseNetworkName(value, pid: currentPid, command: currentCommand,
                                               family: currentFamily, metadata: metadata[currentPid]!) {
                    entries.append(entry)
                }
            default:
                break
            }
        }

        return entries
    }

    private func parseNetworkName(_ name: String, pid: pid_t, command: String,
                                  family explicitFamily: PortEntry.AddressFamily?,
                                  metadata: (Date, String, String?)) -> PortEntry? {
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

        let family: PortEntry.AddressFamily = explicitFamily ?? (parts.address.contains(":") ? .ipv6 : .ipv4)
        let displayAddress = parts.address == "*" ? (family == .ipv6 ? "::" : "0.0.0.0") : parts.address

        return PortEntry(
            pid: pid,
            port: port,
            processName: command,
            executablePath: metadata.1,
            protocol: .tcp,
            state: .listen,
            family: family,
            localAddress: displayAddress,
            processStartTime: metadata.0,
            scriptPath: metadata.2
        )
    }
}
