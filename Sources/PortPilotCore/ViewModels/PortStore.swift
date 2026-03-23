import Foundation

// MARK: - GroupMode

public enum GroupMode: String, CaseIterable, Sendable {
    case project, portRange, flat
}

// MARK: - PortGroup

public struct PortGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let entries: [PortEntry]

    public init(id: String, name: String, entries: [PortEntry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

// MARK: - PortCategory

public enum PortCategory: String, Sendable {
    case system      // 1-1023
    case databases   // well-known DB ports
    case devServers  // 3000-9999 minus DBs
    case highPorts   // 10000+

    public static let knownDatabases: Set<UInt16> = [
        3306, 5432, 6379, 27017, 9200, 26257, 8529, 7687,
    ]

    public static let infrastructurePorts: Set<UInt16> = [1355, 2375, 2376]

    public static func categorize(_ port: UInt16) -> PortCategory {
        if knownDatabases.contains(port) { return .databases }
        if infrastructurePorts.contains(port) { return .system }
        if port <= 1023 { return .system }
        if port >= 10000 { return .highPorts }
        return .devServers
    }

    public var displayName: String {
        switch self {
        case .system: return "System (1-1023)"
        case .databases: return "Databases"
        case .devServers: return "Dev Servers (3000-9999)"
        case .highPorts: return "High Ports (10000+)"
        }
    }
}

// MARK: - PortStore

@MainActor
@Observable
public final class PortStore {
    public var entries: [PortEntry] = []
    public var searchText: String = ""
    public var groupMode: GroupMode = .project
    public var isScanning = false

    private let scanner: any PortScanning
    private let resolver: ProjectResolver
    private var scanTask: Task<Void, Never>?

    public init(scanner: any PortScanning = LsofScanner(), resolver: ProjectResolver = ProjectResolver()) {
        self.scanner = scanner
        self.resolver = resolver
    }

    // MARK: - Computed properties

    public var filteredEntries: [PortEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { entry in
            String(entry.port).contains(query)
                || entry.processName.lowercased().contains(query)
                || (entry.projectPath?.lowercased().contains(query) ?? false)
        }
    }

    public var grouped: [PortGroup] {
        let source = filteredEntries
        switch groupMode {
        case .project:
            return groupByProject(source)
        case .portRange:
            return groupByPortRange(source)
        case .flat:
            return [PortGroup(id: "all", name: "All Ports", entries: source.sorted { $0.port < $1.port })]
        }
    }

    public var listeningCount: Int {
        entries.filter { $0.state == .listen }.count
    }

    // MARK: - Polling

    public func startPolling() {
        stopPolling()
        scanTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let interval: UInt64 = ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? 5_000_000_000  // 5s
                    : 2_000_000_000  // 2s
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func stopPolling() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Refresh

    public func refresh() async {
        isScanning = true
        var scanned = await scanner.scan()

        // IPv6 dedup: merge entries with same (port, pid) but different address families
        scanned = dedupIPv6(scanned)

        // Resolve project paths
        for i in scanned.indices {
            let entry = scanned[i]
            if let project = resolver.resolve(pid: entry.pid, startTime: entry.processStartTime) {
                scanned[i].projectPath = project
            }
        }

        entries = scanned
        isScanning = false
    }

    // MARK: - Private helpers

    private func dedupIPv6(_ entries: [PortEntry]) -> [PortEntry] {
        struct DedupKey: Hashable {
            let port: UInt16
            let pid: pid_t
            let `protocol`: PortEntry.PortProtocol
        }

        var seen: [DedupKey: Int] = [:]  // key -> index in result
        var result: [PortEntry] = []

        for entry in entries {
            let key = DedupKey(port: entry.port, pid: entry.pid, protocol: entry.protocol)
            if let existingIdx = seen[key] {
                // Prefer IPv4 entry
                if entry.family == .ipv4 {
                    result[existingIdx] = entry
                }
                // Otherwise keep the existing one
            } else {
                seen[key] = result.count
                result.append(entry)
            }
        }

        return result
    }

    private func groupByProject(_ entries: [PortEntry]) -> [PortGroup] {
        var groups: [String: [PortEntry]] = [:]
        for entry in entries {
            let key = entry.projectPath ?? "(no project)"
            groups[key, default: []].append(entry)
        }
        return groups.map { key, entries in
            PortGroup(
                id: "project-\(key)",
                name: key,
                entries: entries.sorted { $0.port < $1.port }
            )
        }.sorted { $0.name < $1.name }
    }

    private func groupByPortRange(_ entries: [PortEntry]) -> [PortGroup] {
        var groups: [PortCategory: [PortEntry]] = [:]
        for entry in entries {
            let cat = PortCategory.categorize(entry.port)
            groups[cat, default: []].append(entry)
        }
        let order: [PortCategory] = [.system, .databases, .devServers, .highPorts]
        return order.compactMap { cat in
            guard let entries = groups[cat], !entries.isEmpty else { return nil }
            return PortGroup(
                id: "range-\(cat.rawValue)",
                name: cat.displayName,
                entries: entries.sorted { $0.port < $1.port }
            )
        }
    }
}
