import Observation
import XCTest
@testable import PortPilotCore

private struct FlakyScanner: PortScanning {
    let entries: [PortEntry]
    let failing: FailureFlag
    func scan() async -> PortScanResult {
        failing.value ? .failure(.allScannersFailed) : .success(entries: entries, source: .lsof)
    }
}

private final class FailureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

@MainActor
final class ServeRouteStoreTests: XCTestCase {
    private let ipn = "/Applications/Tailscale.app/Contents/PlugIns/IPNExtension.appex/Contents/MacOS/IPNExtension"

    private func store(
        entries: [PortEntry] = [],
        scanner: (any PortScanning)? = nil,
        reader: (any ServeStatusReading)?,
        probe: ProbeRecorder,
        clock: ServeTestClock
    ) -> PortStore {
        PortStore(
            scanner: scanner ?? MockScanner(entries: entries),
            serveReader: reader,
            backendProbe: probe.probing,
            now: clock.now
        )
    }

    private let deadRoute = ServeFixture.proxies([(8443, "http://127.0.0.1:3456")])

    func testNoReaderNeverReadsOrProbes() async {
        let probe = ProbeRecorder()
        let store = PortStore(scanner: MockScanner(entries: []), backendProbe: probe.probing)
        for _ in 0..<5 {
            await store.refresh()
            await store.waitForServeEvaluation()
        }
        XCTAssertEqual(store.serveFindings, [])
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0, "serve checks must stay off unless a reader is injected")
    }

    func testDeadRouteConfirmedAfterSixtySecondsAndLoopbackListenerNeverProbed() async {
        let clock = ServeTestClock()
        let t0 = clock.date
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let reader = MockServeReader(.data(ServeFixture.proxies([
            (8443, "http://127.0.0.1:3456"), (4391, "http://localhost:4391"),
        ])))
        let node = makeEntry(pid: 9, port: 4391, name: "node", family: .ipv6)
        let s = store(entries: [node], reader: reader, probe: probe, clock: clock)

        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [], "one dead sample must not be reported")
        clock.advance(by: 60)
        await s.refresh(); await s.waitForServeEvaluation()

        XCTAssertEqual(s.serveFindings.map(\.route.port), [8443])
        XCTAssertEqual(s.serveFindings.first?.noticedAt, t0, "noticedAt must be the first dead sample")
        let calls = await probe.calls
        XCTAssertFalse(calls.contains(4391), "a route with a visible listener must not be probed")
    }

    func testFailedScanDoesNotAdvanceOrClearStreak() async {
        let clock = ServeTestClock()
        let failing = FailureFlag()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let reader = MockServeReader(.data(deadRoute))
        let s = store(scanner: FlakyScanner(entries: [], failing: failing), reader: reader, probe: probe, clock: clock)

        await s.refresh(); await s.waitForServeEvaluation()
        failing.value = true
        clock.advance(by: 30)
        await s.refresh(); await s.waitForServeEvaluation()
        let callsAfterFailure = await probe.callCount
        XCTAssertEqual(callsAfterFailure, 1, "a failed scan must not trigger an evaluation")
        XCTAssertEqual(s.serveFindings, [])

        failing.value = false
        clock.advance(by: 30)
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings.count, 1, "streak survives a failed scan in between")
    }

    func testReaderErrorFromStartYieldsNoFindingsAndNoScanError() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder()
        let s = store(reader: MockServeReader(.failure), probe: probe, clock: clock)
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [])
        XCTAssertNil(s.scanError, "missing Tailscale must not surface as a scan error")
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testLastGoodRoutesKeptUntilTTLThenCleared() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let reader = MockServeReader(.data(deadRoute))
        let s = store(reader: reader, probe: probe, clock: clock)

        await s.refresh(); await s.waitForServeEvaluation()
        await reader.setOutcome(.failure)
        clock.advance(by: 100)
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings.count, 1)

        clock.advance(by: 199)  // t=299
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings.count, 1, "routes read 299 s ago are still trusted")

        clock.advance(by: 2)  // t=301
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [], "stale routes must stop producing findings after the TTL")
    }

    func testReadsThrottledToOncePerThirtySeconds() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let reader = MockServeReader(.data(deadRoute))
        let s = store(reader: reader, probe: probe, clock: clock)
        for _ in 0..<10 {
            await s.refresh(); await s.waitForServeEvaluation()
            clock.advance(by: 6)
        }
        let count = await reader.callCount
        XCTAssertLessThanOrEqual(count, 2)
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testSlowReaderDoesNotBlockRefresh() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder()
        let reader = MockServeReader(.data(deadRoute), gated: true)
        let node = makeEntry(pid: 1, port: 3000, name: "node")
        let s = store(entries: [node], reader: reader, probe: probe, clock: clock)

        await s.refresh()  // returns while the read is still gated
        XCTAssertFalse(s.isScanning)
        XCTAssertEqual(s.entries.count, 1, "entries must publish before the serve read finishes")
        await reader.release()
        await s.waitForServeEvaluation()
    }

    func testBlockedProbeDoesNotBlockRefresh() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(blocking: true)
        let s = store(reader: MockServeReader(.data(deadRoute)), probe: probe, clock: clock)
        await s.refresh()
        XCTAssertFalse(s.isScanning, "refresh must return while the probe is pending")
        await probe.waitForCalls(1)
        await probe.release()
        await s.waitForServeEvaluation()
    }

    func testPublicationDuringProbeDiscardsOlderResults() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead], blocking: true)
        let s = store(reader: MockServeReader(.data(deadRoute)), probe: probe, clock: clock)

        await s.refresh()
        await probe.waitForCalls(1)
        clock.advance(by: 120)
        await s.refresh()  // publishes while the first evaluation is pending
        await probe.release()
        await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [])

        // The discarded evaluation recorded nothing, so this is only the first dead sample.
        clock.advance(by: 120)
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [], "a discarded evaluation must not advance the streak")
    }

    func testCancelRefreshDiscardsPendingProbeResults() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead], blocking: true)
        let s = store(reader: MockServeReader(.data(deadRoute)), probe: probe, clock: clock)

        await s.refresh()
        await probe.waitForCalls(1)
        s.cancelRefresh()
        await probe.release()
        await s.waitForServeEvaluation()

        clock.advance(by: 120)
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [], "cancelled evaluation must not count toward confirmation")
    }

    func testProbesCappedAtThirtyTwoAndRestCountedUnchecked() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder()
        let routes = (0..<40).map { (port: 9000 + $0, target: "http://127.0.0.1:\(20000 + $0)") }
        let s = store(reader: MockServeReader(.data(ServeFixture.proxies(routes))), probe: probe, clock: clock)
        await s.refresh(); await s.waitForServeEvaluation()
        let calls = await probe.callCount
        XCTAssertEqual(calls, 32)
        XCTAssertEqual(s.uncheckedServeRouteCount, 8)
    }

    func testFindingsForEntryOnlyOnTailscaleListener() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let s = store(reader: MockServeReader(.data(deadRoute)), probe: probe, clock: clock)
        await s.refresh(); await s.waitForServeEvaluation()
        clock.advance(by: 60)
        await s.refresh(); await s.waitForServeEvaluation()

        let tailscale = makeEntry(pid: 5, port: 8443, name: "IPNExtension", executablePath: ipn)
        let node = makeEntry(pid: 6, port: 8443, name: "node")
        XCTAssertEqual(s.serveFindings(for: tailscale).count, 1)
        XCTAssertEqual(s.serveFindings(for: node), [], "findings belong to the Tailscale row, not another process on that port")
    }

    // Bug caught: a backwards clock makes the read interval negative, so the reader is never called again.
    func testBackwardsClockStillTriggersReadAndTreatsOldRoutesAsStale() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let reader = MockServeReader(.data(deadRoute))
        let s = store(reader: reader, probe: probe, clock: clock)

        await s.refresh(); await s.waitForServeEvaluation()
        clock.advance(by: -100)
        await s.refresh(); await s.waitForServeEvaluation()
        let count = await reader.callCount
        XCTAssertEqual(count, 2, "negative elapsed time must count as a read being due")

        await reader.setOutcome(.failure)
        clock.advance(by: -100)
        await s.refresh(); await s.waitForServeEvaluation()
        XCTAssertEqual(s.serveFindings, [])
        let calls = await probe.callCount
        XCTAssertEqual(calls, 2, "routes read in the future must be stale, so no third probe")
    }

    // Bug caught: dead candidate routes are probed one after another (or in batches),
    // so one evaluation takes N x probe time. Counts probes in flight, not wall time.
    func testDeadCandidatesAreProbedConcurrently() async {
        actor InFlight {
            private(set) var current = 0, peak = 0, started = 0
            func enter() { current += 1; started += 1; peak = max(peak, current) }
            func exit() { current -= 1 }
        }
        let gauge = InFlight()
        let routes = (0..<4).map { (port: 9000 + $0, target: "http://127.0.0.1:\(20000 + $0)") }
        // Each probe waits (up to 2 s) for all four to be running, so serial probing peaks at 1.
        let gated: BackendProbing = { _, _ in
            await gauge.enter()
            for _ in 0..<200 where await gauge.started < routes.count {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await gauge.exit()
            return .dead
        }
        let s = PortStore(
            scanner: MockScanner(entries: []),
            serveReader: MockServeReader(.data(ServeFixture.proxies(routes))),
            backendProbe: gated, now: ServeTestClock().now)
        await s.refresh()
        await s.waitForServeEvaluation()
        let peak = await gauge.peak
        XCTAssertEqual(peak, routes.count, "all dead candidates must be probed at the same time")
    }

    // Bug caught: a dead sample after a restart gap does not restart the streak, confirming a route that flapped.
    func testRestartFlapRestartsStreak() async {
        let clock = ServeTestClock()
        let scanner = ScriptedScanner()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let s = PortStore(
            scanner: scanner, serveReader: MockServeReader(.data(deadRoute)),
            backendProbe: probe.probing, now: clock.now)
        let node = makeEntry(pid: 9, port: 3456, name: "node", family: .ipv4, address: "127.0.0.1")

        var elapsed: TimeInterval = 0
        func step(at t: TimeInterval, listening: Bool) async {
            clock.advance(by: t - elapsed)
            elapsed = t
            await scanner.set(listening ? [node] : [])
            await s.refresh(); await s.waitForServeEvaluation()
        }
        await step(at: 0, listening: false)
        await step(at: 30, listening: true)
        await step(at: 60, listening: false)
        await step(at: 90, listening: false)
        XCTAssertEqual(s.serveFindings, [], "streak restarted at t=60, only 30 s old at t=90")
        await step(at: 120, listening: false)
        XCTAssertEqual(s.serveFindings.count, 1)
        XCTAssertEqual(s.serveFindings.first?.noticedAt, Date(timeIntervalSince1970: 1_000_060))
    }

    // Bug caught: unchanged results are re-assigned every poll, churning @Observable views.
    func testUnchangedFindingsAreNotRepublished() async {
        let clock = ServeTestClock()
        let probe = ProbeRecorder(liveness: [3456: .dead])
        let s = store(reader: MockServeReader(.data(deadRoute)), probe: probe, clock: clock)
        let changes = ChangeCounter()
        func observe() {
            withObservationTracking { _ = s.serveFindings; _ = s.uncheckedServeRouteCount } onChange: {
                changes.increment()
            }
        }
        await s.refresh(); await s.waitForServeEvaluation()
        clock.advance(by: 60)
        await s.refresh(); await s.waitForServeEvaluation()
        observe()
        for _ in 0..<3 {
            clock.advance(by: 2)
            await s.refresh(); await s.waitForServeEvaluation()
        }
        XCTAssertEqual(changes.value, 0)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private actor ScriptedScanner: PortScanning {
    private var entries: [PortEntry] = []
    func set(_ entries: [PortEntry]) { self.entries = entries }
    func scan() async -> PortScanResult { .success(entries: entries, source: .lsof) }
}
