import Foundation

public enum ConflictDetector: Sendable {
    /// Finds listening TCP bindings from different PIDs that overlap.
    ///
    /// IPv4 and IPv6 are treated as disjoint because PortEntry does not expose
    /// IPV6_V6ONLY. Within a family, wildcard bindings overlap every address;
    /// otherwise only identical local addresses overlap.
    public static func detect(in entries: [PortEntry]) -> [PortConflict] {
        let listeners = entries.filter {
            $0.protocol == .tcp && $0.state == .listen
        }

        return Dictionary(grouping: listeners, by: \.port)
            .compactMap { port, entries in
                let conflictingEntries = entries.filter { candidate in
                    entries.contains { other in
                        candidate.pid != other.pid && bindingsOverlap(candidate, other)
                    }
                }
                return conflictingEntries.isEmpty
                    ? nil
                    : PortConflict(port: port, entries: conflictingEntries)
            }
            .sorted { $0.port < $1.port }
    }

    private static func bindingsOverlap(_ lhs: PortEntry, _ rhs: PortEntry) -> Bool {
        guard lhs.family == rhs.family else { return false }
        return isWildcard(lhs) || isWildcard(rhs) || lhs.localAddress == rhs.localAddress
    }

    private static func isWildcard(_ entry: PortEntry) -> Bool {
        switch entry.family {
        case .ipv4:
            return entry.localAddress == "0.0.0.0" || entry.localAddress == "*"
        case .ipv6:
            return entry.localAddress == "::"
        }
    }
}
