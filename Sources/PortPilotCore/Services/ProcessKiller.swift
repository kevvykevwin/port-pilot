import Darwin
import Foundation

public enum KillResult: Sendable, Equatable {
    case terminated            // Target exited, or the checked signal was sent successfully
    case forceKillNeeded       // SIGTERM sent, target still alive after grace period
    case permissionDenied      // EPERM — not owner
    case processGone           // ESRCH — already exited
    case staleProcess          // PID now belongs to a different process
    case identityUnavailable   // Process exists, but its identity cannot be verified
    case failed(String)        // Other error
}

enum SignalAttempt: Sendable, Equatable {
    case success
    case failure(Int32)
}

typealias ProcessIdentityLookup = @Sendable (pid_t) -> Date?
typealias ProcessSignalSender = @Sendable (pid_t, Int32) -> SignalAttempt

public enum ProcessKiller {
    /// Attempt graceful termination, verifying the PID still belongs to the
    /// process represented by the scanned row before sending SIGTERM.
    public static func terminate(pid: pid_t, expectedStartTime: Date) -> KillResult {
        terminate(
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: LibProc.processStartTime,
            signalSender: sendSystemSignal
        )
    }

    /// Attempt graceful termination with a grace period. SIGKILL is never sent
    /// automatically; callers must explicitly invoke `forceKill`.
    public static func terminateWithGrace(
        pid: pid_t,
        expectedStartTime: Date,
        graceSeconds: TimeInterval = 2.0
    ) async -> KillResult {
        await terminateWithGrace(
            pid: pid,
            expectedStartTime: expectedStartTime,
            graceSeconds: graceSeconds,
            identityLookup: LibProc.processStartTime,
            signalSender: sendSystemSignal
        )
    }

    /// Force kill after re-verifying process identity. The fresh check prevents
    /// a PID reused during the grace period from receiving SIGKILL.
    public static func forceKill(pid: pid_t, expectedStartTime: Date) -> KillResult {
        forceKill(
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: LibProc.processStartTime,
            signalSender: sendSystemSignal
        )
    }

    /// Check if a process is still running.
    public static func isRunning(pid: pid_t) -> Bool {
        sendSystemSignal(pid, 0) == .success
    }

    static func terminate(
        pid: pid_t,
        expectedStartTime: Date,
        identityLookup: ProcessIdentityLookup,
        signalSender: ProcessSignalSender
    ) -> KillResult {
        sendCheckedSignal(
            SIGTERM,
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: identityLookup,
            signalSender: signalSender
        )
    }

    static func terminateWithGrace(
        pid: pid_t,
        expectedStartTime: Date,
        graceSeconds: TimeInterval,
        identityLookup: ProcessIdentityLookup,
        signalSender: ProcessSignalSender
    ) async -> KillResult {
        let initialResult = terminate(
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: identityLookup,
            signalSender: signalSender
        )
        guard initialResult == .terminated else { return initialResult }

        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while Date() < deadline {
            switch identityStatus(
                pid: pid,
                expectedStartTime: expectedStartTime,
                identityLookup: identityLookup,
                signalSender: signalSender
            ) {
            case .matches:
                break
            case .gone, .stale:
                return .terminated
            case .unavailable:
                return .identityUnavailable
            }

            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return .failed("Termination cancelled")
            }
        }

        switch identityStatus(
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: identityLookup,
            signalSender: signalSender
        ) {
        case .matches:
            return .forceKillNeeded
        case .gone, .stale:
            return .terminated
        case .unavailable:
            return .identityUnavailable
        }
    }

    static func forceKill(
        pid: pid_t,
        expectedStartTime: Date,
        identityLookup: ProcessIdentityLookup,
        signalSender: ProcessSignalSender
    ) -> KillResult {
        sendCheckedSignal(
            SIGKILL,
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: identityLookup,
            signalSender: signalSender
        )
    }

    private enum IdentityStatus {
        case matches
        case gone
        case stale
        case unavailable
    }

    private static func identityStatus(
        pid: pid_t,
        expectedStartTime: Date,
        identityLookup: ProcessIdentityLookup,
        signalSender: ProcessSignalSender
    ) -> IdentityStatus {
        if let liveStartTime = identityLookup(pid) {
            return liveStartTime == expectedStartTime ? .matches : .stale
        }

        switch signalSender(pid, 0) {
        case .failure(ESRCH):
            return .gone
        case .success, .failure:
            return .unavailable
        }
    }

    private static func sendCheckedSignal(
        _ signal: Int32,
        pid: pid_t,
        expectedStartTime: Date,
        identityLookup: ProcessIdentityLookup,
        signalSender: ProcessSignalSender
    ) -> KillResult {
        switch identityStatus(
            pid: pid,
            expectedStartTime: expectedStartTime,
            identityLookup: identityLookup,
            signalSender: signalSender
        ) {
        case .matches:
            break
        case .gone:
            return .processGone
        case .stale:
            return .staleProcess
        case .unavailable:
            return .identityUnavailable
        }

        switch signalSender(pid, signal) {
        case .success:
            return .terminated
        case .failure(EPERM):
            return .permissionDenied
        case .failure(ESRCH):
            return .processGone
        case .failure(let errorNumber):
            return .failed(String(cString: strerror(errorNumber)))
        }
    }

    private static func sendSystemSignal(_ pid: pid_t, _ signal: Int32) -> SignalAttempt {
        kill(pid, signal) == 0 ? .success : .failure(errno)
    }
}
