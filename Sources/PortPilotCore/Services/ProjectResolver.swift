import Darwin
import Foundation

public final class ProjectResolver: Sendable {

    // MARK: - Cache types

    private struct CacheKey: Hashable {
        let pid: pid_t
        let startTime: Date
    }

    private struct CacheEntry {
        let key: CacheKey
        let value: String?
    }

    private let lock = NSLock()
    private let _cache = _MutableState()

    /// Mutable state protected by NSLock.
    /// Class reference so we can mutate through a `let` on a Sendable type.
    private final class _MutableState: @unchecked Sendable {
        var entries: [CacheKey: String?] = [:]
        var order: [CacheKey] = []  // oldest first
    }

    private static let maxCacheSize = 500
    private static let evictCount = 100

    // MARK: - Project markers (checked in order)

    private static let projectMarkers: [String] = [
        ".git",
        "package.json",
        "pyproject.toml",
        "Cargo.toml",
        "go.mod",
        "mix.exs",
        "Gemfile",
        "Package.swift",
    ]

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Resolves a process's working directory to the nearest project root.
    /// Returns the project directory name (e.g., "sift-coffee") or nil.
    public func resolve(pid: pid_t, startTime: Date) -> String? {
        let key = CacheKey(pid: pid, startTime: startTime)

        // Check cache
        let cached: String?? = withLock { _cache.entries[key] }
        if let cached { return cached }

        // Cache miss — resolve
        let result = resolveProjectName(pid: pid)

        // Store in cache
        withLock {
            _cache.entries[key] = result
            _cache.order.append(key)

            if _cache.order.count > Self.maxCacheSize {
                let toRemove = Array(_cache.order.prefix(Self.evictCount))
                _cache.order.removeFirst(Self.evictCount)
                for old in toRemove {
                    _cache.entries.removeValue(forKey: old)
                }
            }
        }

        return result
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Private

    private func resolveProjectName(pid: pid_t) -> String? {
        guard let cwd = processCwd(pid: pid), !cwd.isEmpty else {
            return nil
        }
        return findProjectRoot(from: cwd)
    }

    /// Gets the current working directory of a process via proc_pidinfo.
    private func processCwd(pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(size))
        guard result == size else { return nil }

        let path = withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                String(cString: cStr)
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Walks up from `startPath` looking for project marker files/dirs.
    /// Returns the directory name of the project root, or nil.
    private func findProjectRoot(from startPath: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var current = startPath

        while current != "/" && current != home {
            for marker in Self.projectMarkers {
                let markerPath = (current as NSString).appendingPathComponent(marker)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: markerPath, isDirectory: &isDir) {
                    // .git must be a directory; others are files
                    if marker == ".git" && !isDir.boolValue { continue }
                    return (current as NSString).lastPathComponent
                }
            }
            current = (current as NSString).deletingLastPathComponent
        }

        return nil
    }
}

// MARK: - Darwin constant

private let PROC_PIDVNODEPATHINFO: Int32 = 9
