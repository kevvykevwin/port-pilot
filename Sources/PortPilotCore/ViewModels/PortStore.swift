import Foundation

// MARK: - GroupMode

public enum GroupMode: String, CaseIterable, Sendable {
    case project, type
}

// MARK: - PortGroup

public struct PortGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let entries: [PortEntry]
    public let collapsedByDefault: Bool

    public init(id: String, name: String, entries: [PortEntry], collapsedByDefault: Bool = false) {
        self.id = id
        self.name = name
        self.entries = entries
        self.collapsedByDefault = collapsedByDefault
    }
}

// MARK: - PortCategory

public enum PortCategory: String, Sendable {
    case devServers  // actual dev tools (node, python, etc.)
    case databases   // well-known DB ports
    case apps        // macOS apps using any port
    case system      // system services
    case highPorts   // 10000+

    public static let knownDatabases: Set<UInt16> = [
        3306, 5432, 6379, 27017, 9200, 26257, 8529, 7687,
    ]

    public static let infrastructurePorts: Set<UInt16> = [1355, 2375, 2376]

    /// Known dev runtime process names
    public static let devRuntimes: Set<String> = [
        "node", "python3", "python", "ruby", "java", "go",
        "bun", "deno", "cargo", "mix", "beam.smp",
        "next-server", "vite", "webpack", "esbuild", "tsx",
        "uvicorn", "gunicorn", "flask", "rails", "puma",
        "php", "nginx", "caddy",
    ]

    /// Categorize using both port AND process context
    public static func categorize(_ entry: PortEntry) -> PortCategory {
        if knownDatabases.contains(entry.port) { return .databases }
        if isMacApp(entry) { return .apps }
        if infrastructurePorts.contains(entry.port) { return .system }
        if entry.port <= 1023 { return .system }
        if isDevProcess(entry) { return .devServers }
        if entry.projectPath != nil { return .devServers }
        if entry.port >= 10000 { return .highPorts }
        return .devServers
    }

    /// Port-only categorize (backward compat for tests)
    public static func categorize(_ port: UInt16) -> PortCategory {
        if knownDatabases.contains(port) { return .databases }
        if infrastructurePorts.contains(port) { return .system }
        if port <= 1023 { return .system }
        if port >= 10000 { return .highPorts }
        return .devServers
    }

    private static func isDevProcess(_ entry: PortEntry) -> Bool {
        if devRuntimes.contains(entry.processName) { return true }
        let path = entry.executablePath
        // Common dev tool paths
        if path.contains("/node_modules/") { return true }
        if path.contains("/.cargo/") { return true }
        if path.contains("/go/bin/") { return true }
        if path.contains("/.local/bin/") { return true }
        return false
    }

    static func isMacApp(_ entry: PortEntry) -> Bool {
        let path = entry.executablePath
        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/") { return true }
        if path.contains("/usr/libexec/") || path.contains("/usr/sbin/") { return true }
        if path.contains(".app/") { return true }
        let knownApps: Set<String> = [
            "Spotify", "LINE", "ControlCenter", "rapportd", "figma_agent",
            "Slack", "Discord", "zoom.us", "Notion", "Safari",
        ]
        return knownApps.contains(entry.processName)
    }

    public var displayName: String {
        switch self {
        case .devServers: return "Dev Servers"
        case .databases: return "Databases"
        case .apps: return "macOS Apps"
        case .system: return "System"
        case .highPorts: return "High Ports"
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
        case .type:
            return groupByPortRange(source)
        }
    }

    public var listeningCount: Int {
        entries.filter { $0.state == .listen }.count
    }

    /// Projects with 2+ listening ports — potential dupes worth flagging
    public var multiPortProjects: Set<String> {
        let counts = Dictionary(grouping: entries.compactMap(\.projectPath), by: { $0 })
            .filter { $0.value.count >= 2 }
        return Set(counts.keys)
    }

    /// True when any dev project has multiple ports (triggers lighthouse glow)
    public var hasMultiPortProjects: Bool {
        !multiPortProjects.isEmpty
    }

    // MARK: - Polling

    private static let pollIntervalNormal: UInt64    = 2_000_000_000  // 2s
    private static let pollIntervalLowPower: UInt64  = 5_000_000_000  // 5s

    public func startPolling() {
        stopPolling()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? Self.pollIntervalLowPower
                    : Self.pollIntervalNormal
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
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
        var projectGroups: [String: [PortEntry]] = [:]
        var macApps: [PortEntry] = []

        for entry in entries {
            if let project = entry.projectPath {
                projectGroups[project, default: []].append(entry)
            } else if PortCategory.isMacApp(entry) {
                macApps.append(entry)
            } else {
                projectGroups["Other", default: []].append(entry)
            }
        }

        // Dev projects first (sorted), then "macOS Apps" collapsed at bottom
        var result = projectGroups.map { key, entries in
            PortGroup(
                id: "project-\(key)",
                name: key,
                entries: entries.sorted { $0.port < $1.port }
            )
        }.sorted { $0.name < $1.name }

        if !macApps.isEmpty {
            result.append(PortGroup(
                id: "macos-apps",
                name: "macOS Apps",
                entries: macApps.sorted { $0.port < $1.port },
                collapsedByDefault: true
            ))
        }

        return result
    }

    private func groupByPortRange(_ entries: [PortEntry]) -> [PortGroup] {
        var groups: [PortCategory: [PortEntry]] = [:]
        for entry in entries {
            let cat = PortCategory.categorize(entry)
            groups[cat, default: []].append(entry)
        }
        let order: [PortCategory] = [.devServers, .databases, .system, .apps, .highPorts]
        return order.compactMap { cat in
            guard let entries = groups[cat], !entries.isEmpty else { return nil }
            return PortGroup(
                id: "range-\(cat.rawValue)",
                name: cat.displayName,
                entries: entries.sorted { $0.port < $1.port },
                collapsedByDefault: cat == .highPorts || cat == .apps
            )
        }
    }
}
