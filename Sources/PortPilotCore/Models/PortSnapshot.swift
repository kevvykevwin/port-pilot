import Foundation

public struct PortSnapshot: Sendable {
    public let entries: [PortEntry]
    public let timestamp: Date

    public init(entries: [PortEntry], timestamp: Date = .now) {
        self.entries = entries
        self.timestamp = timestamp
    }

    public func diff(from previous: PortSnapshot) -> SnapshotDiff {
        let previousIDs = Set(previous.entries.map(\.id))
        let currentIDs = Set(entries.map(\.id))

        let added = entries.filter { !previousIDs.contains($0.id) }
        let removed = previous.entries.filter { !currentIDs.contains($0.id) }

        return SnapshotDiff(added: added, removed: removed)
    }
}

public struct SnapshotDiff: Sendable {
    public let added: [PortEntry]
    public let removed: [PortEntry]
}
