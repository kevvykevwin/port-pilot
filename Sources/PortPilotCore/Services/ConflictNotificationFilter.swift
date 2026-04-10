import Foundation

/// Decides which conflicts should trigger notifications.
/// Stateful — tracks last-notification time per port for debouncing.
/// Pure logic (no UI/system dependencies) so it can be unit tested in PortPilotCore.
public struct ConflictNotificationFilter: Sendable {
    public private(set) var lastNotified: [UInt16: Date] = [:]
    public static let debounceInterval: TimeInterval = 30

    public init() {}

    /// Returns conflicts that should trigger a notification.
    /// Fires only when a newly-added entry is part of a conflict,
    /// debounced per-port across the interval window.
    /// Also prunes stale debounce entries for conflicts that have resolved.
    public mutating func portsToNotify(
        diff: SnapshotDiff?,
        conflicts: [PortConflict],
        now: Date = .now
    ) -> [PortConflict] {
        // Prune stale entries for resolved conflicts
        let activeConflictPorts = Set(conflicts.map(\.port))
        lastNotified = lastNotified.filter { activeConflictPorts.contains($0.key) }

        guard let diff, !diff.added.isEmpty else { return [] }
        let addedPorts = Set(diff.added.map(\.port))
        var result: [PortConflict] = []

        for conflict in conflicts where addedPorts.contains(conflict.port) {
            if let last = lastNotified[conflict.port],
               now.timeIntervalSince(last) < Self.debounceInterval {
                continue
            }
            lastNotified[conflict.port] = now
            result.append(conflict)
        }
        return result
    }
}
