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

    /// Display labels for identifier values. Ports and PIDs are identifiers,
    /// not quantities — they must never render with locale grouping
    /// separators (":8,317"). Views must consume these via `Text(verbatim:)`;
    /// interpolating the raw integers into a `Text` literal selects the
    /// `LocalizedStringKey` overload, which locale-formats them.
    public var portLabel: String { ":\(String(port))" }
    public var pidLabel: String { "pid \(String(pid))" }

    /// Concise project name for display. `projectPath` remains the full root
    /// path used for grouping and identity.
    public var projectDisplayName: String? {
        projectPath.map { ProjectDisplayName.label(for: $0) }
    }

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

    public var vsCodeExtensionDescription: String? {
        guard processName.hasPrefix("Code Helper") else { return nil }
        guard let extID = VSCodeExtensions.extractExtensionID(from: executablePath) else { return nil }
        return VSCodeExtensions.knownExtensions[extID] ?? extID
    }

    public enum PortProtocol: String, Sendable { case tcp, udp }
    public enum PortState: String, Sendable { case listen, established, other }
    public enum AddressFamily: String, Sendable { case ipv4, ipv6 }
}

public enum ProjectDisplayName {
    /// Returns the final path component for a single project root.
    public static func label(for rootPath: String) -> String {
        URL(fileURLWithPath: rootPath).standardizedFileURL.lastPathComponent
    }

    /// Returns concise labels keyed by full project root. Equal basenames gain
    /// only enough parent context to distinguish the simultaneously shown roots.
    public static func labels(for rootPaths: some Sequence<String>) -> [String: String] {
        let roots = Array(Set(rootPaths))
        let rootsByBaseName = Dictionary(grouping: roots, by: label)
        var labels: [String: String] = [:]

        for (baseName, matchingRoots) in rootsByBaseName {
            guard matchingRoots.count > 1 else {
                labels[matchingRoots[0]] = baseName
                continue
            }

            let componentsByRoot = Dictionary(uniqueKeysWithValues: matchingRoots.map {
                ($0, pathComponents(for: $0))
            })

            for root in matchingRoots {
                guard let components = componentsByRoot[root] else { continue }
                var resolvedLabel = root

                if components.count >= 2 {
                    for depth in 2...components.count {
                        let suffix = components.suffix(depth).joined(separator: "/")
                        let isUnique = matchingRoots.allSatisfy { candidate in
                            candidate == root
                                || componentsByRoot[candidate]?.suffix(depth).joined(separator: "/")
                                    != suffix
                        }
                        if isUnique {
                            resolvedLabel = suffix
                            break
                        }
                    }
                }

                labels[root] = resolvedLabel
            }
        }

        return labels
    }

    private static func pathComponents(for rootPath: String) -> [String] {
        URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
            .filter { $0 != "/" }
    }
}
