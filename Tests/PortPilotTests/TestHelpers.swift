import Darwin
import Foundation
@testable import PortPilotCore

func makeEntry(
    pid: pid_t, port: UInt16, name: String,
    family: PortEntry.AddressFamily = .ipv4,
    state: PortEntry.PortState = .listen,
    executablePath: String? = nil,
    startTime: Date = Date(timeIntervalSince1970: 1000),
    address: String? = nil,
    scriptPath: String? = nil
) -> PortEntry {
    PortEntry(
        pid: pid, port: port, processName: name,
        executablePath: executablePath ?? "/usr/bin/\(name)", protocol: .tcp,
        state: state, family: family,
        localAddress: address ?? (family == .ipv4 ? "127.0.0.1" : "::1"),
        processStartTime: startTime, scriptPath: scriptPath
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
    var requestCount: Int { nextRequestID }
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

// MARK: - Serve route helpers

final class ServeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    var date: Date { lock.withLock { current } }
    var now: @Sendable () -> Date { { [self] in date } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

actor MockServeReader: ServeStatusReading {
    enum Outcome: Sendable { case data(Data), failure }
    struct ReadFailure: Error {}

    private var outcome: Outcome
    private var gated: Bool
    private var gate: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    /// `gated` readers block inside `read()` until `release()`.
    init(_ outcome: Outcome, gated: Bool = false) {
        self.outcome = outcome
        self.gated = gated
    }

    func release() {
        gated = false
        let pending = gate
        gate = []
        pending.forEach { $0.resume() }
    }

    func setOutcome(_ outcome: Outcome) { self.outcome = outcome }

    func read() async throws -> Data {
        callCount += 1
        if gated { await withCheckedContinuation { gate.append($0) } }
        switch outcome {
        case .data(let data): return data
        case .failure: throw ReadFailure()
        }
    }
}

/// Stub probe: returns a configured liveness per port, records calls, and can hold
/// every call until `release()`.
actor ProbeRecorder {
    private var liveness: [UInt16: BackendLiveness]
    private let defaultLiveness: BackendLiveness
    private var blocking: Bool
    private(set) var calls: [UInt16] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(liveness: [UInt16: BackendLiveness] = [:], default defaultLiveness: BackendLiveness = .dead, blocking: Bool = false) {
        self.liveness = liveness
        self.defaultLiveness = defaultLiveness
        self.blocking = blocking
    }

    var callCount: Int { calls.count }

    func probe(port: UInt16) async -> BackendLiveness {
        calls.append(port)
        let ready = callWaiters.filter { calls.count >= $0.count }
        callWaiters.removeAll { calls.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if blocking {
            await withCheckedContinuation { waiters.append($0) }
        }
        return liveness[port] ?? defaultLiveness
    }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func release() {
        blocking = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    nonisolated var probing: BackendProbing {
        { [self] _, port in await self.probe(port: port) }
    }
}

enum ServeFixture {
    static let host = "fixture.tailnet.ts.net"

    /// HTTPS proxy routes, each mounted at "/" on its own selector port.
    static func proxies(_ routes: [(port: Int, target: String)]) -> Data {
        var tcp: [String: Any] = [:]
        var web: [String: Any] = [:]
        for route in routes {
            tcp[String(route.port)] = ["HTTPS": true]
            web["\(host):\(route.port)"] = ["Handlers": ["/": ["Proxy": route.target]]]
        }
        let root: [String: Any] = ["TCP": tcp, "Web": web]
        return try! JSONSerialization.data(withJSONObject: root)
    }
}
