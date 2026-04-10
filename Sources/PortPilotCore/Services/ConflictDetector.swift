import Foundation

public enum ConflictDetector: Sendable {
    /// Finds ports claimed by 2+ different PIDs.
    public static func detect(in entries: [PortEntry]) -> [PortConflict] {
        Dictionary(grouping: entries, by: \.port)
            .compactMap { port, entries in
                Set(entries.map(\.pid)).count >= 2
                    ? PortConflict(port: port, entries: entries)
                    : nil
            }
            .sorted { $0.port < $1.port }
    }
}
