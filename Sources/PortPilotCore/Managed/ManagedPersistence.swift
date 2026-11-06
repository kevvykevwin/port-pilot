import Foundation
import Darwin

public final class ManagedLifecycleLock {
    private let fd: Int32
    public init(root: URL) throws {
        fd = open(root.appendingPathComponent("lifecycle.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagedError.recoveryRequired }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ManagedError.operationInProgress }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
    /// True when another open file description (another process, or a live `ManagedLifecycleLock`)
    /// holds the lifecycle lock. Probes with a non-blocking exclusive lock and releases it at once.
    /// An unopenable lock file fails closed as `.recoveryRequired`.
    public static func isHeld(root: URL) throws -> Bool {
        let probe = open(root.appendingPathComponent("lifecycle.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard probe >= 0 else { throw ManagedError.recoveryRequired }
        defer { close(probe) }
        if flock(probe, LOCK_EX | LOCK_NB) == 0 { flock(probe, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
}

/// Lifetime singleton lock. Files are opened without following symlinks; existing
/// permissions/ownership are checked rather than silently adopting another root.
public final class ManagedPersistence: @unchecked Sendable {
    public let root: URL
    private let lockFD: Int32
    private let writeFault: @Sendable (String) -> Bool
    public init(root: URL, writeFault: @escaping @Sendable (String) -> Bool = { _ in false }) throws {
        self.writeFault = writeFault
        self.root = root.standardizedFileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ManagedError.unauthorized }
        lockFD = open(root.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ManagedError.recoveryRequired }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); throw ManagedError.operationInProgress
        }
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD) }
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PortPilot/Managed")
    }
    public func read(_ name: String) throws -> Data? {
        let path = root.appendingPathComponent(name).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw ManagedError.recoveryRequired }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 32 * 1024 * 1024 else { throw ManagedError.recoveryRequired }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw ManagedError.recoveryRequired }
        return data
    }
    public func write(_ name: String, data: Data) throws {
        guard !writeFault(name) else { throw ManagedError.recoveryRequired }
        let temporary = root.appendingPathComponent(".write-\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagedError.recoveryRequired }
        defer { close(fd); unlink(temporary) }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ManagedError.recoveryRequired }; offset += n
        }
        guard fsync(fd) == 0, rename(temporary, root.appendingPathComponent(name).path) == 0 else {
            throw ManagedError.recoveryRequired
        }
        let directory = open(root.path, O_RDONLY | O_CLOEXEC)
        defer { if directory >= 0 { close(directory) } }
        guard directory >= 0, fsync(directory) == 0 else { throw ManagedError.recoveryRequired }
    }
    /// Removes one regular file from the state root. Missing files are not an error.
    public func remove(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/") else { throw ManagedError.invalidInput }
        if unlink(root.appendingPathComponent(name).path) != 0 && errno != ENOENT { throw ManagedError.recoveryRequired }
    }
    public func names(withPrefix prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    }
    func load() throws -> ManagedState {
        guard let data = try read("registry.json") else {
            // A journal without a snapshot indicates an interrupted commit.
            guard try read("intent.json") == nil else { throw ManagedError.recoveryRequired }
            return ManagedState()
        }
        let state = try JSONDecoder().decode(ManagedState.self, from: data)
        guard state.schema == 1 else { throw ManagedError.recoveryRequired }
        if let intent = try read("intent.json") {
            let proposed = try JSONDecoder().decode(ManagedState.self, from: intent)
            guard proposed.schema == 1, proposed.revision == state.revision, intent == data else { throw ManagedError.recoveryRequired }
        }
        return state
    }
    func commit(_ state: ManagedState) throws {
        let data = try ManagedDigest.canonical(state)
        // This journal holds the next complete transaction, including any fenced
        // external intent. An interrupted transaction fails closed on next load.
        try write("intent.json", data: data)
        try write("registry.json", data: data)
    }
}
