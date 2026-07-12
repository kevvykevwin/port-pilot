import Darwin
import Foundation
@testable import PortPilotCore

func makeEntry(
    pid: pid_t, port: UInt16, name: String,
    family: PortEntry.AddressFamily = .ipv4,
    state: PortEntry.PortState = .listen,
    executablePath: String? = nil
) -> PortEntry {
    PortEntry(
        pid: pid, port: port, processName: name,
        executablePath: executablePath ?? "/usr/bin/\(name)", protocol: .tcp,
        state: state, family: family,
        localAddress: family == .ipv4 ? "127.0.0.1" : "::1",
        processStartTime: .now
    )
}

struct MockScanner: PortScanning {
    let entries: [PortEntry]
    func scan() async -> [PortEntry] { entries }
}
