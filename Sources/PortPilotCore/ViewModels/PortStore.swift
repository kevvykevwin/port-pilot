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

// MARK: - PortStore

@MainActor
@Observable
public final class PortStore {
    public var entries: [PortEntry] = []
    public var searchText: String = ""
    public var groupMode: GroupMode = .project
    public var isScanning = false
    public private(set) var scanError: PortScanError?
    public private(set) var lastScanSource: PortScanSource?
    public private(set) var lastSuccessfulScan: Date?
    public private(set) var lastScanDuration: TimeInterval?
    private var preferences: ProcessPreferences
    private let defaults: UserDefaults?
    private var refreshTask: Task<Void, Never>?

    private let scanner: any PortScanning
    private let resolver: ProjectResolver
    private var scanTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var previousSnapshot: PortSnapshot?
    @ObservationIgnored public private(set) var lastDiff: SnapshotDiff?

    public init(
        scanner: any PortScanning = ResilientPortScanner(),
        resolver: ProjectResolver = ProjectResolver(),
        defaults: UserDefaults? = nil
    ) {
        self.scanner = scanner
        self.resolver = resolver
        self.defaults = defaults
        self.preferences = ProcessPreferences.load(from: defaults)
    }

    // MARK: - Computed properties

    public var filteredEntries: [PortEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return displayEntries }
        return displayEntries.filter { entry in
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
        displayEntries.filter { $0.state == .listen }.count
    }

    /// Full bindings remain in entries. Only presentation combines address families.
    public var displayEntries: [PortEntry] {
        var rows: [String: PortEntry] = [:]
        for entry in entries {
            if let existing = rows[entry.rowID], existing.family == .ipv4 { continue }
            rows[entry.rowID] = entry
        }
        return rows.values.sorted { ($0.port, $0.pid, $0.id) < ($1.port, $1.pid, $1.id) }
    }

    public func classification(for entry: PortEntry) -> ProcessClassification {
        let override = ProcessClassifier.overrideKey(for: entry).flatMap { preferences.categories[$0] }
        return ProcessClassifier.classify(entry, override: override)
    }

    public func setCategory(_ category: PortCategory?, for entry: PortEntry) {
        guard let key = ProcessClassifier.overrideKey(for: entry) else { return }
        preferences.categories[key] = category
        preferences.save(to: defaults)
    }

    public func bindingSummary(for entry: PortEntry) -> String {
        let bindings = entries.filter { $0.rowID == entry.rowID }
        return Set(bindings.map { "\($0.family.rawValue) \($0.localAddress) · \($0.exposure)" }).sorted().joined(separator: "\n")
    }

    public func projectOwner(for entry: PortEntry) -> String? {
        classification(for: entry).resolvesProject ? entry.projectPath : nil
    }

    private func projectServices(_ root: String) -> [PortEntry] {
        displayEntries.filter { $0.state == .listen && projectOwner(for: $0) == root }
    }

    public func rememberExpectedServices(for root: String) {
        let services = projectServices(root)
        guard !services.isEmpty else { return }
        preferences.expectedServices[root] = Set(services.map(ProcessClassifier.serviceKey))
        preferences.save(to: defaults)
    }

    public func clearExpectedServices(for root: String) {
        preferences.expectedServices.removeValue(forKey: root)
        preferences.save(to: defaults)
    }

    public func hasExpectedServices(for root: String) -> Bool {
        preferences.expectedServices[root] != nil
    }

    /// Unconfigured multi-service projects warrant review, not a duplicate claim.
    /// A remembered baseline tolerates normal restarts and absent services, but
    /// still flags new identities/endpoints and concurrent duplicate services.
    public var multiPortProjects: Set<String> {
        var byProject: [String: [PortEntry]] = [:]
        for entry in displayEntries where entry.state == .listen {
            if let root = projectOwner(for: entry) { byProject[root, default: []].append(entry) }
        }
        return Set(byProject.keys.filter { root in
            let services = byProject[root, default: []]
            guard let expected = preferences.expectedServices[root] else { return services.count >= 2 }
            let keys = services.map(ProcessClassifier.serviceKey)
            return keys.contains { !expected.contains($0) } || Set(keys).count < keys.count
        })
    }

    public var conflictingRowIDs: Set<String> {
        Set(conflicts.flatMap(\.entries).map(\.rowID))
    }

    /// True when project services need review (triggers the amber lighthouse).
    public var hasMultiPortProjects: Bool {
        !multiPortProjects.isEmpty
    }

    /// Observed overlapping bindings, not evidence of a failed bind attempt.
    public var conflicts: [PortConflict] {
        ConflictDetector.detect(in: entries)
    }

    public var hasConflicts: Bool {
        !conflicts.isEmpty
    }

    public var conflictingPorts: Set<UInt16> {
        Set(conflicts.map(\.port))
    }

    /// Callback fired after every refresh with diff + current conflicts.
    /// Used by ConflictNotifier to dispatch macOS notifications.
    @ObservationIgnored
    public var onRefreshComplete: (@MainActor @Sendable (_ diff: SnapshotDiff?, _ conflicts: [PortConflict]) -> Void)?

    // MARK: - Polling

    // Fast cadence only while the menu is open; slow background cadence otherwise.
    // Each refresh() forks an lsof subprocess (kernel fd-table walk) — keeping that
    // at 2s around the clock is what flags the app as "Using Significant Energy".
    private static let pollIntervalActive: UInt64     =  2_000_000_000  // 2s — menu open
    private static let pollIntervalBackground: UInt64 = 30_000_000_000  // 30s — menu closed
    private static let pollIntervalLowPower: UInt64   = 60_000_000_000  // 60s — Low Power Mode

    private var isActive = false

    private func nextInterval() -> UInt64 {
        // Active (menu open) always polls fast — the window is short-lived, so the
        // energy cost is bounded, and stale data while the user is looking is worse.
        // Low Power Mode only stretches the slow background cadence.
        if isActive { return Self.pollIntervalActive }
        return ProcessInfo.processInfo.isLowPowerModeEnabled
            ? Self.pollIntervalLowPower
            : Self.pollIntervalBackground
    }

    /// Switch cadence when the menu opens/closes. Opening restarts the loop so the
    /// list reflects current state immediately and switches to the fast interval;
    /// closing lets the running loop pick up the slow interval on its next tick.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { startPolling() }
    }

    public func startPolling() {
        stopPolling()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.pollOnce() else { return }
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
            }
        }
    }

    private func pollOnce() async -> UInt64 {
        await refresh()
        return nextInterval()
    }

    public func stopPolling() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Refresh

    /// Concurrent callers share one scan, enrichment pass and publication.
    /// Cancelling a polling waiter does not cancel another caller's refresh.
    public func refresh() async {
        guard !Task.isCancelled else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isScanning = true
        let task = Task<Void, Never> { [weak self] in
            await self?.performRefresh(generation: generation)
        }
        refreshTask = task
        await task.value
        if generation == refreshGeneration { refreshTask = nil }
    }

    public func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isScanning = false
    }

    private func performRefresh(generation: UInt64) async {
        let scanner = scanner
        let resolver = resolver
        let started = Date()
        let worker = Task.detached(priority: .utility) {
            let result = await scanner.scan()
            guard case .success(var scanned, let source) = result else { return result }
            var projects: [String: String] = [:]
            var resolved: Set<String> = []
            for i in scanned.indices {
                guard !Task.isCancelled else { return PortScanResult.failure(.cancelled) }
                let entry = scanned[i]
                guard ProcessClassifier.classify(entry).resolvesProject else { continue }
                if resolved.insert(entry.processIdentity).inserted {
                    projects[entry.processIdentity] = resolver.resolve(pid: entry.pid, startTime: entry.processStartTime)
                }
                if let root = projects[entry.processIdentity] { scanned[i].projectPath = root }
            }
            // Remove identical duplicate file-descriptor records, never bindings.
            var seen: Set<String> = []
            scanned = scanned.filter { seen.insert($0.id).inserted }
            return PortScanResult.success(entries: scanned, source: source)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard generation == refreshGeneration else { return }
        defer { isScanning = false }
        guard !Task.isCancelled else { return }
        guard case .success(let scanned, let source) = result else {
            if case .failure(let error) = result, error != .cancelled { scanError = error }
            return
        }
        scanError = nil
        lastScanSource = source
        lastSuccessfulScan = Date()
        lastScanDuration = Date().timeIntervalSince(started)
        entries = scanned
        let snapshot = PortSnapshot(entries: scanned)
        lastDiff = previousSnapshot.map { snapshot.diff(from: $0) }
        previousSnapshot = snapshot
        onRefreshComplete?(lastDiff, conflicts)
    }

    // MARK: - Grouping

    private func groupByProject(_ entries: [PortEntry]) -> [PortGroup] {
        var projectGroups: [String: [PortEntry]] = [:]
        var macApps: [PortEntry] = []

        for entry in entries {
            let classification = classification(for: entry)
            if classification.category == .infrastructure || classification.ownership == .system {
                projectGroups["Other", default: []].append(entry)
            } else if classification.ownership == .app {
                macApps.append(entry)
            } else if let project = entry.projectPath {
                projectGroups[project, default: []].append(entry)
            } else {
                projectGroups["Other", default: []].append(entry)
            }
        }

        let displayNames = ProjectDisplayName.labels(
            for: projectGroups.keys.filter { $0 != "Other" }
        )

        // Dev projects first (sorted), then "macOS Apps" collapsed at bottom
        var result = projectGroups.map { key, entries in
            PortGroup(
                id: "project-\(key)",
                name: key == "Other" ? key : displayNames[key] ?? key,
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
            let cat = classification(for: entry).category
            groups[cat, default: []].append(entry)
        }
        let order = PortCategory.allCases
        return order.compactMap { cat in
            guard let entries = groups[cat], !entries.isEmpty else { return nil }
            return PortGroup(
                id: "range-\(cat.rawValue)",
                name: cat.displayName,
                entries: entries.sorted { $0.port < $1.port },
                collapsedByDefault: cat == .apps || cat == .editorServices || cat == .system
            )
        }
    }
}
