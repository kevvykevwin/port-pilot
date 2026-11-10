import Foundation
import Darwin

/// Registers a kernel fork/exit watch before the child executes user code.
/// NOTE_TRACK is unavailable on macOS: any fork permanently invalidates the
/// completeness proof, even if a later ancestry sample finds some children.
public final class ManagedTrackedChild: @unchecked Sendable {
    public let identity: ManagedIncarnation
    private let events: Int32
    private let lock = NSLock()
    private var uncertain = false
    private var resumed = false
    private var exited = false
    private var reaped = false

    public init(launch: ManagedLaunch, port: UInt16, environment: [String: String]) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ManagedError.dependencyUnavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ManagedError.dependencyUnavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, launch.cwd) == 0 else { throw ManagedError.invalidInput }
        for descriptor: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else { throw ManagedError.dependencyUnavailable }
        }
        let arguments = [launch.executable] + launch.arguments.map { $0 == "{port}" ? String(port) : $0 }
        var argv = arguments.map { strdup($0) } + [nil]
        var env = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: Int32 = 0
        let result = posix_spawn(&pid, launch.executable, &actions, &attributes, &argv, &env)
        guard result == 0 else { throw ManagedError.dependencyUnavailable }
        guard let identity = ManagedProcess.incarnation(pid: pid) else {
            Self.killAndReap(pid)
            throw ManagedError.identityUnavailable
        }
        self.identity = identity
        let fd = kqueue()
        guard fd >= 0 else {
            Self.killAndReap(pid)
            throw ManagedError.dependencyUnavailable
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var watch = kevent64_s()
        watch.ident = UInt64(pid); watch.filter = Int16(EVFILT_PROC); watch.flags = UInt16(EV_ADD | EV_CLEAR)
        watch.fflags = UInt32(NOTE_FORK) | UInt32(NOTE_EXIT)
        guard kevent64(fd, &watch, 1, nil, 0, 0, nil) == 0 else {
            close(fd)
            Self.killAndReap(pid)
            throw ManagedError.dependencyUnavailable
        }
        events = fd
    }
    deinit { close(events) }
    /// Kills and reaps a child this initializer just spawned (still suspended, never resumed). Its PID cannot
    /// be reused until it is reaped, so a plain SIGKILL by PID is safe; SIGKILL always ends a stopped process,
    /// so the blocking wait returns. EINTR is retried so no zombie is left behind.
    private static func killAndReap(_ pid: Int32) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    public func resume() throws {
        try lock.withLock {
            guard !resumed, ManagedProcess.incarnation(pid: identity.pid) == identity else { throw ManagedError.staleIdentity }
            guard kill(identity.pid, SIGCONT) == 0 else { throw ManagedError.dependencyUnavailable }
            resumed = true
        }
    }
    public func treeVerified() -> Bool {
        lock.withLock {
            var event = kevent64_s(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
            for _ in 0..<16 {
                let count = kevent64(events, nil, 0, &event, 1, 0, &timeout)
                if count == 0 {
                    if exited { reapOriginalChild() }
                    return !uncertain
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    uncertain = true; return false
                }
                if event.flags & UInt16(EV_ERROR) != 0 || event.fflags & UInt32(NOTE_FORK) != 0 { uncertain = true }
                if event.fflags & UInt32(NOTE_EXIT) != 0 {
                    exited = true
                    // Reap only this child, never consume Foundation's children.
                    reapOriginalChild()
                }
            }
            uncertain = true
            return false
        }
    }
    private func reapOriginalChild() {
        guard !reaped else { return }
        if let live = ManagedProcess.incarnation(pid: identity.pid), live != identity { reaped = true; return }
        var status: Int32 = 0
        let result = waitpid(identity.pid, &status, WNOHANG)
        if result == identity.pid || (result < 0 && errno == ECHILD) { reaped = true }
    }
    /// True once the kernel has reaped this child, so its PID reports ESRCH and exit can be proven.
    public var isReaped: Bool { lock.withLock { reaped } }
    public func discardUnstarted() {
        lock.withLock {
            guard !resumed else { return }
            _ = ProcessKiller.forceKill(pid: identity.pid, expectedStartTime: identity.startTime)
        }
    }
}

public final class ManagedTreeEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [UUID: ManagedTrackedChild] = [:]
    public init() {}
    public func record(_ child: ManagedTrackedChild, service: UUID) { lock.withLock { children[service] = child } }
    public func verified(_ service: UUID) -> Bool { lock.withLock { children[service]?.treeVerified() ?? false } }
}
