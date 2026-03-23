import Darwin
import Foundation

public enum KillResult: Sendable, Equatable {
    case terminated            // SIGTERM succeeded, process exited
    case forceKillNeeded       // SIGTERM sent, process still alive after grace period
    case permissionDenied      // EPERM — not owner
    case processGone           // ESRCH — already exited
    case failed(String)        // Other error
}

public enum ProcessKiller {
    /// Attempt graceful termination. Returns immediately with initial result.
    public static func terminate(pid: pid_t) -> KillResult {
        let result = kill(pid, SIGTERM)
        if result == 0 { return .terminated }

        switch errno {
        case EPERM: return .permissionDenied
        case ESRCH: return .processGone
        default: return .failed(String(cString: strerror(errno)))
        }
    }

    /// Attempt graceful termination with grace period, then force kill if needed.
    public static func terminateWithGrace(pid: pid_t, graceSeconds: TimeInterval = 2.0) async -> KillResult {
        let initialResult = terminate(pid: pid)
        guard initialResult == .terminated else { return initialResult }

        // Wait for grace period, checking if process exited
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            // Check if process still exists
            if kill(pid, 0) != 0 && errno == ESRCH {
                return .terminated  // Process exited cleanly
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        // Still alive after grace period
        if kill(pid, 0) == 0 {
            return .forceKillNeeded
        }
        return .terminated
    }

    /// Force kill (SIGKILL). No grace period.
    public static func forceKill(pid: pid_t) -> KillResult {
        let result = kill(pid, SIGKILL)
        if result == 0 { return .terminated }

        switch errno {
        case EPERM: return .permissionDenied
        case ESRCH: return .processGone
        default: return .failed(String(cString: strerror(errno)))
        }
    }

    /// Check if a process is still running.
    public static func isRunning(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
