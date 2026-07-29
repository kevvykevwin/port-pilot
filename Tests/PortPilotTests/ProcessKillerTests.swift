import Darwin
import Foundation
import XCTest
@testable import PortPilotCore

final class ProcessKillerTests: XCTestCase {

    func testMatchingIdentitySendsSIGTERM() {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = ProcessKiller.terminate(
            pid: 42,
            expectedStartTime: expectedStartTime,
            identityLookup: { _ in expectedStartTime },
            signalSender: recorder.sender(returning: .success)
        )

        XCTAssertEqual(result, .terminated)
        XCTAssertEqual(recorder.signals, [SIGTERM])
    }

    func testMismatchedIdentityDoesNotSignal() {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = ProcessKiller.terminate(
            pid: 42,
            expectedStartTime: expectedStartTime,
            identityLookup: { _ in Date(timeIntervalSince1970: 2_000) },
            signalSender: recorder.sender(returning: .success)
        )

        XCTAssertEqual(result, .staleProcess)
        XCTAssertTrue(recorder.signals.isEmpty)
    }

    func testAlreadyGoneProcessDoesNotReceiveTerminationSignal() {
        let recorder = SignalRecorder()

        let result = ProcessKiller.terminate(
            pid: 42,
            expectedStartTime: Date(timeIntervalSince1970: 1_000),
            identityLookup: { _ in nil },
            signalSender: recorder.sender { signal in
                signal == 0 ? .failure(ESRCH) : .success
            }
        )

        XCTAssertEqual(result, .processGone)
        XCTAssertEqual(recorder.signals, [0])
        XCTAssertFalse(recorder.signals.contains(SIGTERM))
        XCTAssertFalse(recorder.signals.contains(SIGKILL))
    }

    func testUnavailableIdentityDoesNotSignal() {
        let recorder = SignalRecorder()

        let result = ProcessKiller.terminate(
            pid: 42,
            expectedStartTime: Date(timeIntervalSince1970: 1_000),
            identityLookup: { _ in nil },
            signalSender: recorder.sender(returning: .failure(EPERM))
        )

        XCTAssertEqual(result, .identityUnavailable)
        XCTAssertEqual(recorder.signals, [0])
        XCTAssertFalse(recorder.signals.contains(SIGTERM))
        XCTAssertFalse(recorder.signals.contains(SIGKILL))
    }

    func testForceKillRechecksIdentityBeforeSIGKILL() {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = ProcessKiller.forceKill(
            pid: 42,
            expectedStartTime: expectedStartTime,
            identityLookup: { _ in Date(timeIntervalSince1970: 2_000) },
            signalSender: recorder.sender(returning: .success)
        )

        XCTAssertEqual(result, .staleProcess)
        XCTAssertTrue(recorder.signals.isEmpty)
    }

    func testForceKillWithMatchingIdentitySendsSIGKILL() {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = ProcessKiller.forceKill(
            pid: 42,
            expectedStartTime: expectedStartTime,
            identityLookup: { _ in expectedStartTime },
            signalSender: recorder.sender(returning: .success)
        )

        XCTAssertEqual(result, .terminated)
        XCTAssertEqual(recorder.signals, [SIGKILL])
    }

    func testPermissionDeniedFromSIGTERMIsReported() {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = ProcessKiller.terminate(
            pid: 42,
            expectedStartTime: expectedStartTime,
            identityLookup: { _ in expectedStartTime },
            signalSender: recorder.sender(returning: .failure(EPERM))
        )

        XCTAssertEqual(result, .permissionDenied)
        XCTAssertEqual(recorder.signals, [SIGTERM])
    }

    func testGenericSignalErrorIsReported() {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = ProcessKiller.terminate(
            pid: 42,
            expectedStartTime: expectedStartTime,
            identityLookup: { _ in expectedStartTime },
            signalSender: recorder.sender(returning: .failure(EIO))
        )

        XCTAssertEqual(result, .failed(String(cString: strerror(EIO))))
        XCTAssertEqual(recorder.signals, [SIGTERM])
    }

    func testMatchingProcessStillRunningAfterGraceNeedsExplicitForceKill() async {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let recorder = SignalRecorder()

        let result = await ProcessKiller.terminateWithGrace(
            pid: 42,
            expectedStartTime: expectedStartTime,
            graceSeconds: 0,
            identityLookup: { _ in expectedStartTime },
            signalSender: recorder.sender(returning: .success)
        )

        XCTAssertEqual(result, .forceKillNeeded)
        XCTAssertEqual(recorder.signals, [SIGTERM])
        XCTAssertFalse(recorder.signals.contains(SIGKILL))
    }

    func testIdentityUnavailableAfterSIGTERMDoesNotSendSIGKILL() async {
        let expectedStartTime = Date(timeIntervalSince1970: 1_000)
        let identities = IdentityRecorder([expectedStartTime, nil])
        let signals = SignalRecorder()

        let result = await ProcessKiller.terminateWithGrace(
            pid: 42,
            expectedStartTime: expectedStartTime,
            graceSeconds: 0,
            identityLookup: identities.lookup,
            signalSender: signals.sender(returning: .success)
        )

        XCTAssertEqual(result, .identityUnavailable)
        XCTAssertEqual(signals.signals, [SIGTERM, 0])
        XCTAssertFalse(signals.signals.contains(SIGKILL))
    }

    func testKillSpawnedProcess() async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["999"]
        try task.run()
        let childPid = task.processIdentifier

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(ProcessKiller.isRunning(pid: childPid))
        let expectedStartTime = try XCTUnwrap(LibProc.processStartTime(pid: childPid))

        let result = await ProcessKiller.terminateWithGrace(
            pid: childPid,
            expectedStartTime: expectedStartTime,
            graceSeconds: 2.0
        )

        switch result {
        case .terminated, .processGone:
            break
        case .forceKillNeeded:
            _ = ProcessKiller.forceKill(pid: childPid, expectedStartTime: expectedStartTime)
            XCTFail("Process did not exit after SIGTERM grace period")
        case .permissionDenied:
            XCTFail("SIGTERM permission denied")
        case .staleProcess:
            XCTFail("Spawned process identity changed unexpectedly")
        case .identityUnavailable:
            XCTFail("Spawned process identity could not be verified")
        case .failed(let message):
            XCTFail("Kill failed: \(message)")
        }

        XCTAssertFalse(ProcessKiller.isRunning(pid: childPid))
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSignals: [Int32] = []

    var signals: [Int32] {
        lock.withLock { recordedSignals }
    }

    func sender(returning result: SignalAttempt) -> ProcessSignalSender {
        sender { _ in result }
    }

    func sender(
        resultForSignal: @escaping @Sendable (Int32) -> SignalAttempt
    ) -> ProcessSignalSender {
        { [self] _, signal in
            lock.withLock {
                recordedSignals.append(signal)
            }
            return resultForSignal(signal)
        }
    }
}

private final class IdentityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Date?]

    init(_ identities: [Date?]) {
        self.identities = identities
    }

    var lookup: ProcessIdentityLookup {
        { [self] _ in
            lock.withLock {
                identities.isEmpty ? nil : identities.removeFirst()
            }
        }
    }
}
