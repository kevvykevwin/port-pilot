import Darwin
import Foundation
@testable import PortPilotCore

func makeEntry(
    pid: pid_t, port: UInt16, name: String,
    family: PortEntry.AddressFamily = .ipv4,
    state: PortEntry.PortState = .listen,
    executablePath: String? = nil
) -> PortEntry {
    PortEntry(
        pid: pid, port: port, processName: name,
        executablePath: executablePath ?? "/usr/bin/\(name)", protocol: .tcp,
        state: state, family: family,
        localAddress: family == .ipv4 ? "127.0.0.1" : "::1",
        processStartTime: .now
    )
}

struct MockScanner: PortScanning {
    let entries: [PortEntry]
    func scan() async -> PortScanResult {
        .success(entries: entries, source: .lsof)
    }
}

actor ControlledScanner: PortScanning {
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<PortScanResult, Never>] = [:]
    private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func scan() async -> PortScanResult {
        await withCheckedContinuation { continuation in
            let requestID = nextRequestID
            nextRequestID += 1
            continuations[requestID] = continuation
            resumeSatisfiedWaiters()
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard nextRequestID < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func completeRequest(_ requestID: Int, with entries: [PortEntry]) {
        completeRequest(
            requestID,
            with: .success(entries: entries, source: .lsof)
        )
    }

    func completeRequest(_ requestID: Int, with result: PortScanResult) {
        precondition(
            continuations[requestID] != nil,
            "Request \(requestID) is not pending"
        )
        continuations.removeValue(forKey: requestID)?.resume(returning: result)
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = requestCountWaiters.filter { nextRequestID >= $0.count }
        requestCountWaiters.removeAll { nextRequestID >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
