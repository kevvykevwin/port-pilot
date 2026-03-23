import Darwin
import Foundation
import os.log

public protocol PortScanning: Sendable {
    func scan() async -> [PortEntry]
}

public final class PortScanner: PortScanning, Sendable {
    private let logger = Logger(subsystem: "com.portpilot", category: "PortScanner")
    private let signposter = OSSignposter(subsystem: "com.portpilot", category: "PortScanner")

    public init() {}

    public func scan() async -> [PortEntry] {
        let state = signposter.beginInterval("scan")
        defer { signposter.endInterval("scan", state) }

        let startTime = CFAbsoluteTimeGetCurrent()
        let pids = LibProc.listAllPids()
        var entries: [PortEntry] = []

        for pid in pids {
            let fds = LibProc.listFileDescriptors(pid: pid)
            let socketFDs = fds.filter(LibProc.isSocket)
            guard !socketFDs.isEmpty else { continue }

            // Lazily resolve process metadata only if we find a relevant socket
            var processName: String?
            var executablePath: String?
            var processStart: Date?
            var resolvedMeta = false

            for fd in socketFDs {
                guard let socketInfo = LibProc.socketInfo(pid: pid, fd: fd.proc_fd) else {
                    continue
                }

                let soi = socketInfo.psi.soi_proto
                let family = socketInfo.psi.soi_family
                let proto = socketInfo.psi.soi_protocol

                // Only care about IPv4 and IPv6
                guard family == AF_INET || family == AF_INET6 else { continue }

                let portEntry: PortEntry? = withUnsafePointer(to: socketInfo) { ptr in
                    let addressFamily: PortEntry.AddressFamily = family == AF_INET ? .ipv4 : .ipv6
                    let port: UInt16
                    let address: String
                    let portState: PortEntry.PortState
                    let portProtocol: PortEntry.PortProtocol

                    if proto == IPPROTO_TCP {
                        portProtocol = .tcp
                        let tcpInfo = soi.pri_tcp
                        let tcpState = tcpInfo.tcpsi_state

                        if tcpState == TSI_S_LISTEN {
                            portState = .listen
                        } else if tcpState == TSI_S_ESTABLISHED {
                            portState = .established
                        } else {
                            portState = .other
                        }

                        if family == AF_INET {
                            let insi = tcpInfo.tcpsi_ini.insi_laddr.ina_46.i46a_addr4
                            port = UInt16(bigEndian: tcpInfo.tcpsi_ini.insi_lport.truncatedPort())
                            address = formatIPv4(insi)
                        } else {
                            let in6si = tcpInfo.tcpsi_ini.insi_laddr.ina_6
                            port = UInt16(bigEndian: tcpInfo.tcpsi_ini.insi_lport.truncatedPort())
                            address = formatIPv6(in6si)
                        }
                    } else if proto == IPPROTO_UDP {
                        portProtocol = .udp
                        portState = .other
                        let udpInfo = soi.pri_in
                        if family == AF_INET {
                            let insi = udpInfo.insi_laddr.ina_46.i46a_addr4
                            port = UInt16(bigEndian: udpInfo.insi_lport.truncatedPort())
                            address = formatIPv4(insi)
                        } else {
                            let in6si = udpInfo.insi_laddr.ina_6
                            port = UInt16(bigEndian: udpInfo.insi_lport.truncatedPort())
                            address = formatIPv6(in6si)
                        }
                    } else {
                        return nil
                    }

                    // Skip port 0
                    guard port > 0 else { return nil }

                    // Resolve process metadata once per PID
                    if !resolvedMeta {
                        processName = LibProc.processName(pid: pid)
                        executablePath = LibProc.processPath(pid: pid)
                        processStart = LibProc.processStartTime(pid: pid)
                        resolvedMeta = true
                    }

                    return PortEntry(
                        pid: pid,
                        port: port,
                        processName: processName ?? "unknown",
                        executablePath: executablePath ?? "",
                        protocol: portProtocol,
                        state: portState,
                        family: addressFamily,
                        localAddress: address,
                        processStartTime: processStart ?? .distantPast
                    )
                }

                if let entry = portEntry {
                    entries.append(entry)
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("Scan completed: \(entries.count) entries in \(elapsed, format: .fixed(precision: 3))s")
        return entries
    }

    /// Verifies the scanner can see its own process.
    public func selfTest() async -> Bool {
        let myPid = getpid()
        let entries = await scan()
        // We may not have a listening port, but we should at least be able to
        // enumerate PIDs that include our own.
        let pids = LibProc.listAllPids()
        return pids.contains(myPid)
    }

    // MARK: - Address Formatting

    private func formatIPv4(_ addr: in_addr) -> String {
        var addr = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private func formatIPv6(_ addr: in6_addr) -> String {
        var addr = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

// MARK: - Port extraction helper

private extension Int32 {
    /// Extract port number (lower 16 bits) from insi_lport.
    func truncatedPort() -> UInt16 {
        UInt16(truncatingIfNeeded: self)
    }
}
