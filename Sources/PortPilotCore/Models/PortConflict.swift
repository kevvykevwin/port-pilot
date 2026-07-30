import Foundation

public struct PortConflict: Identifiable, Sendable {
    public let port: UInt16
    public let entries: [PortEntry]

    public init(port: UInt16, entries: [PortEntry]) {
        self.port = port
        self.entries = entries
    }

    public var id: UInt16 { port }

    /// Human label for notifications/UI. Shows concise, disambiguated project
    /// names where available and falls back to process names. Appends PID when
    /// labels still collide.
    public var conflictLabel: String {
        let projectLabels = ProjectDisplayName.labels(
            for: entries.compactMap(\.projectPath)
        )
        let labels = entries.map { entry -> String in
            entry.projectPath.flatMap { projectLabels[$0] } ?? entry.processName
        }
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)

        guard counts.values.contains(where: { $0 > 1 }) else {
            return labels.sorted().joined(separator: " vs ")
        }

        return entries.map { entry in
            let label = entry.projectPath.flatMap { projectLabels[$0] } ?? entry.processName
            return counts[label, default: 0] > 1 ? "\(label) (pid \(entry.pid))" : label
        }
        .sorted()
        .joined(separator: " vs ")
    }
}
