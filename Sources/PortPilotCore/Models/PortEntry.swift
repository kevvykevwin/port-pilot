import Foundation

public struct PortEntry: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let port: UInt16
    public let processName: String
    public let executablePath: String
    public let `protocol`: PortProtocol
    public let state: PortState
    public let family: AddressFamily
    public let localAddress: String
    public let processStartTime: Date
    public var projectPath: String?

    public var id: String { "\(pid)-\(port)-\(`protocol`)" }

    public init(
        pid: pid_t, port: UInt16, processName: String, executablePath: String,
        protocol: PortProtocol, state: PortState, family: AddressFamily,
        localAddress: String, processStartTime: Date, projectPath: String? = nil
    ) {
        self.pid = pid
        self.port = port
        self.processName = processName
        self.executablePath = executablePath
        self.protocol = `protocol`
        self.state = state
        self.family = family
        self.localAddress = localAddress
        self.processStartTime = processStartTime
        self.projectPath = projectPath
    }

    public enum PortProtocol: String, Sendable { case tcp, udp }
    public enum PortState: String, Sendable { case listen, established, other }
    public enum AddressFamily: String, Sendable { case ipv4, ipv6 }
}
