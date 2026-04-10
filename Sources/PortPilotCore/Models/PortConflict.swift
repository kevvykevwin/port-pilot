import Foundation

public struct PortConflict: Identifiable, Sendable {
    public let port: UInt16
    public let entries: [PortEntry]

    public init(port: UInt16, entries: [PortEntry]) {
        self.port = port
        self.entries = entries
    }

    public var id: UInt16 { port }

    /// Human label for notifications/UI. Shows project paths where available,
    /// falls back to process names. Appends PID when names collide.
    public var conflictLabel: String {
        let labels = entries.map { entry -> String in
            entry.projectPath ?? entry.processName
        }
        let unique = Set(labels)
        // If all labels are identical (e.g., two "postgres"), disambiguate with PID
        if unique.count == 1 {
            return entries.map { "\($0.projectPath ?? $0.processName) (pid \($0.pid))" }
                .joined(separator: " vs ")
        }
        return unique.sorted().joined(separator: " vs ")
    }
}
