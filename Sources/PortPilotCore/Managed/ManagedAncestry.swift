import Foundation

/// A bounded observation of descendants whose parent link is still visible.
/// Sampling cannot prove tree completeness: a double-fork can escape between
/// observations. These records authorize identity checks, never blanket PGID kills.
public enum ManagedAncestry {
    public static func discover(known: [ManagedIncarnation],
                                pids: [Int32] = LibProc.listAllPids(),
                                relation: (Int32) -> (parent: Int32, start: Date)? = LibProc.processAncestry,
                                identity: (Int32) -> ManagedIncarnation? = ManagedProcess.incarnation) -> [ManagedIncarnation] {
        var verified = known.filter { identity($0.pid) == $0 }
        var remaining = Set(pids).subtracting(verified.map(\.pid))
        var added: [ManagedIncarnation] = []
        // Bounded by process count even under a continually forking workload.
        for _ in 0..<min(pids.count, 1024) {
            var progress = false
            for pid in remaining.sorted() {
                guard let before = relation(pid),
                      let parent = verified.first(where: { $0.pid == before.parent }),
                      identity(parent.pid) == parent,
                      let child = identity(pid), child.startTime == before.start,
                      child.bootId == parent.bootId, child.hostId == parent.hostId,
                      child.startTime >= parent.startTime,
                      let after = relation(pid), after.parent == before.parent, after.start == before.start,
                      identity(parent.pid) == parent, identity(pid) == child else { continue }
                verified.append(child); added.append(child); remaining.remove(pid); progress = true
            }
            if !progress { break }
        }
        return added
    }
}
