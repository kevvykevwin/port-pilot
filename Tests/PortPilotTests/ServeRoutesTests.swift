import XCTest
@testable import PortPilotCore

final class ServeRoutesTests: XCTestCase {
    private let host = "fixture.tailnet.ts.net"

    private func webJSON(
        port: Int = 8443, tcp: String = "{\"HTTPS\":true}", handlers: String
    ) -> Data {
        Data("""
        {"TCP":{"\(port)":\(tcp)},"Web":{"\(host):\(port)":{"Handlers":\(handlers)}}}
        """.utf8)
    }

    private func proxy(_ target: String, path: String = "/") -> String {
        "{\"\(path)\":{\"Proxy\":\"\(target)\"}}"
    }

    private func backend(of target: String) -> ServeBackend? {
        ServeConfig.parse(webJSON(handlers: proxy(target))).first?.backend
    }

    // MARK: Parsing

    func testHappyPathParsesPortPathBackendAndNoFunnel() {
        let routes = ServeConfig.parse(webJSON(handlers: proxy("http://127.0.0.1:3456")))
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].port, 8443)
        XCTAssertEqual(routes[0].kind, .https)
        XCTAssertEqual(routes[0].path, "/")
        XCTAssertEqual(routes[0].target, "http://127.0.0.1:3456")
        XCTAssertEqual(routes[0].backend, .loopback(host: "127.0.0.1", port: 3456))
        XCTAssertFalse(routes[0].funnel)
    }

    func testLocalhostTargetKeepsLocalhostHost() {
        XCTAssertEqual(backend(of: "http://localhost:4391"), .loopback(host: "localhost", port: 4391))
    }

    func testBracketedIPv6LiteralParsesAsLoopbackColonColonOne() {
        XCTAssertEqual(backend(of: "http://[::1]:3000"), .loopback(host: "::1", port: 3000))
    }

    func testHttpsInsecureSchemeIsParsed() {
        XCTAssertEqual(backend(of: "https+insecure://localhost:8443"), .loopback(host: "localhost", port: 8443))
    }

    func testMissingPortDefaultsTo80ForHttp() {
        XCTAssertEqual(backend(of: "http://localhost"), .loopback(host: "localhost", port: 80))
    }

    func testMissingPortDefaultsTo443ForHttpsAndInsecure() {
        XCTAssertEqual(backend(of: "https://localhost"), .loopback(host: "localhost", port: 443))
        XCTAssertEqual(backend(of: "https+insecure://127.0.0.1"), .loopback(host: "127.0.0.1", port: 443))
    }

    func testUnixSocketTargetIsNotCheckable() {
        XCTAssertEqual(backend(of: "unix:/tmp/s.sock"), .notCheckable)
    }

    func testRemoteHostIsNotCheckable() {
        XCTAssertEqual(backend(of: "http://192.168.1.5:80"), .notCheckable)
    }

    func testPortZeroAndOutOfRangeAreNotCheckable() {
        XCTAssertEqual(backend(of: "http://127.0.0.1:0"), .notCheckable)
        XCTAssertEqual(backend(of: "http://127.0.0.1:65536"), .notCheckable)
    }

    func testNonPrimaryLoopbackAddressIsNotCheckable() {
        XCTAssertEqual(backend(of: "http://127.0.0.2:3000"), .notCheckable)
    }

    func testWildcardTargetIsLoopbackWithZeroHost() {
        XCTAssertEqual(backend(of: "http://0.0.0.0:3000"), .loopback(host: "0.0.0.0", port: 3000))
    }

    func testWebRouteWithoutTCPEntryIsSkipped() {
        let json = Data("""
        {"TCP":{"8443":{"HTTPS":true}},"Web":{"\(host):9000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}}}
        """.utf8)
        XCTAssertEqual(ServeConfig.parse(json), [])
    }

    func testHTTPTCPEntryYieldsHttpKind() {
        let routes = ServeConfig.parse(webJSON(port: 80, tcp: "{\"HTTP\":true}", handlers: proxy("http://127.0.0.1:3000")))
        XCTAssertEqual(routes.first?.kind, .http)
    }

    func testTextHandlerProducesNoRoute() {
        XCTAssertEqual(ServeConfig.parse(webJSON(handlers: "{\"/\":{\"Text\":\"hi\"}}")), [])
    }

    func testPathHandlerProducesNoRoute() {
        XCTAssertEqual(ServeConfig.parse(webJSON(handlers: "{\"/\":{\"Path\":\"/tmp/x\"}}")), [])
    }

    func testMultipleHandlersYieldOneRouteEachSortedByPath() {
        let handlers = "{\"/api\":{\"Proxy\":\"http://127.0.0.1:3001\"},\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"}}"
        let routes = ServeConfig.parse(webJSON(handlers: handlers))
        XCTAssertEqual(routes.map(\.path), ["/", "/api"])
        XCTAssertEqual(routes.map(\.backend), [
            .loopback(host: "127.0.0.1", port: 3000), .loopback(host: "127.0.0.1", port: 3001),
        ])
    }

    func testRoutesSortByPortBeforePath() {
        let json = Data("""
        {"TCP":{"9000":{"HTTPS":true},"443":{"HTTPS":true}},"Web":{
        "\(host):9000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}},
        "\(host):443":{"Handlers":{"/z":{"Proxy":"http://127.0.0.1:2"}}}}}
        """.utf8)
        XCTAssertEqual(ServeConfig.parse(json).map(\.port), [443, 9000])
    }

    func testTCPForwardParsesWithNilPathAndNoScheme() {
        let json = Data("{\"TCP\":{\"5432\":{\"TCPForward\":\"127.0.0.1:15432\"}}}".utf8)
        let routes = ServeConfig.parse(json)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].port, 5432)
        XCTAssertEqual(routes[0].kind, .tcp)
        XCTAssertNil(routes[0].path)
        XCTAssertEqual(routes[0].backend, .loopback(host: "127.0.0.1", port: 15432))
    }

    func testTCPForwardWithBracketedIPv6() {
        let json = Data("{\"TCP\":{\"5432\":{\"TCPForward\":\"[::1]:15432\"}}}".utf8)
        XCTAssertEqual(ServeConfig.parse(json).first?.backend, .loopback(host: "::1", port: 15432))
    }

    func testFunnelFlagIsReadFromAllowFunnelSelector() {
        let json = Data("""
        {"TCP":{"8443":{"HTTPS":true}},"Web":{"\(host):8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}},
        "AllowFunnel":{"\(host):8443":true}}
        """.utf8)
        XCTAssertEqual(ServeConfig.parse(json).first?.funnel, true)
    }

    func testServicesAndForegroundKeysAreIgnored() {
        let json = Data("""
        {"Services":{"svc:web":{"TCP":{"443":{"HTTPS":true}}}},"Foreground":{"x":{}},
        "TCP":{"8443":{"HTTPS":true}},"Web":{"\(host):8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}
        """.utf8)
        XCTAssertEqual(ServeConfig.parse(json).count, 1)
    }

    func testMalformedJSONReturnsEmpty() {
        XCTAssertEqual(ServeConfig.parse(Data("not json".utf8)), [])
    }

    func testEmptyObjectAndNonObjectReturnEmpty() {
        XCTAssertEqual(ServeConfig.parse(Data("{}".utf8)), [])
        XCTAssertEqual(ServeConfig.parse(Data("[1,2]".utf8)), [])
        XCTAssertEqual(ServeConfig.parse(Data()), [])
    }

    func testBodyOverOneMiBReturnsEmptyEvenIfValid() {
        let valid = String(data: webJSON(handlers: proxy("http://127.0.0.1:3000")), encoding: .utf8)!
        let padded = valid + String(repeating: " ", count: 1_048_577 - valid.utf8.count)
        XCTAssertEqual(padded.utf8.count, 1_048_577)
        XCTAssertEqual(ServeConfig.parse(Data(padded.utf8)), [])
        let atLimit = valid + String(repeating: " ", count: 1_048_576 - valid.utf8.count)
        XCTAssertEqual(ServeConfig.parse(Data(atLimit.utf8)).count, 1)
    }

    func testInvalidUTF8ReturnsEmpty() {
        XCTAssertEqual(ServeConfig.parse(Data([0x7B, 0xFF, 0xFE, 0x7D])), [])
    }

    func testChangedTargetIsADifferentRoute() {
        let a = ServeConfig.parse(webJSON(handlers: proxy("http://127.0.0.1:3456")))[0]
        let b = ServeConfig.parse(webJSON(handlers: proxy("http://127.0.0.1:3457")))[0]
        XCTAssertNotEqual(a, b)
    }

    // MARK: Candidate matching

    private func route(_ target: String, port: Int = 8443) -> ServeRoute {
        ServeConfig.parse(webJSON(port: port, handlers: proxy(target)))[0]
    }

    private func node(_ port: UInt16, _ family: PortEntry.AddressFamily, _ address: String) -> PortEntry {
        makeEntry(pid: 10, port: port, name: "node", family: family, address: address)
    }

    func testNoListenerOnTargetPortIsCandidate() {
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3456"), entries: [node(9999, .ipv4, "127.0.0.1")]))
    }

    func testExactIPv4ListenerIsNotCandidate() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [node(3000, .ipv4, "127.0.0.1")]))
    }

    func testDualStackWildcardListenerServesIPv4Target() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [node(3000, .ipv6, "::")]))
    }

    func testIPv4WildcardListenerServesIPv4Target() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [node(3000, .ipv4, "0.0.0.0")]))
    }

    func testStarAddressListenerServesIPv4Target() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [node(3000, .ipv4, "*")]))
    }

    func testLocalhostTargetServedByIPv6OnlyLoopbackListener() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://localhost:4391"), entries: [node(4391, .ipv6, "::1")]))
    }

    func testLocalhostTargetServedByIPv4OnlyLoopbackListener() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://localhost:4391"), entries: [node(4391, .ipv4, "127.0.0.1")]))
    }

    func testIPv6TargetNotServedByIPv4OnlyListener() {
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://[::1]:3000"), entries: [node(3000, .ipv4, "127.0.0.1")]))
    }

    func testIPv6TargetServedByIPv6WildcardAndExact() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://[::1]:3000"), entries: [node(3000, .ipv6, "::")]))
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://[::1]:3000"), entries: [node(3000, .ipv6, "::1")]))
    }

    func testIPv4TargetNotServedByIPv6LoopbackOnlyListener() {
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [node(3000, .ipv6, "::1")]))
    }

    func testIPv4TargetNotServedByListenerOnOtherIPv4Address() {
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [node(3000, .ipv4, "192.168.1.9")]))
    }

    private func ipn(_ port: UInt16, _ family: PortEntry.AddressFamily, _ address: String) -> PortEntry {
        makeEntry(pid: 99, port: port, name: "IPNExtension", family: family,
                  executablePath: "/Applications/Tailscale.app/Contents/PlugIns/IPNExtension.appex/Contents/MacOS/IPNExtension",
                  address: address)
    }

    func testSelfLoopOnTailnetAddressesIsStillCandidate() {
        let entries = [ipn(4392, .ipv4, "100.64.0.1"), ipn(4392, .ipv6, "fd7a::1")]
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:4392", port: 4392), entries: entries))
    }

    func testTailscaleListenerOnLoopbackIsExcludedFromBackendMatching() {
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:4392", port: 4392), entries: [ipn(4392, .ipv4, "127.0.0.1")]))
    }

    func testWildcardTargetTreatedAsIPv4Loopback() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://0.0.0.0:3000"), entries: [node(3000, .ipv4, "127.0.0.1")]))
    }

    func testNonListenStateIsIgnored() {
        let est = makeEntry(pid: 10, port: 3000, name: "node", state: .established, address: "127.0.0.1")
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [est]))
    }

    func testUDPListenerIsIgnored() {
        let base = node(3000, .ipv4, "127.0.0.1")
        let udp = PortEntry(pid: base.pid, port: 3000, processName: "node", executablePath: base.executablePath,
                            protocol: .udp, state: .listen, family: .ipv4, localAddress: "127.0.0.1",
                            processStartTime: base.processStartTime)
        XCTAssertTrue(ServeRouteMatcher.isCandidate(route("http://127.0.0.1:3000"), entries: [udp]))
    }

    func testNotCheckableRouteIsNeverCandidate() {
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("unix:/tmp/s.sock"), entries: []))
        XCTAssertFalse(ServeRouteMatcher.isCandidate(route("http://192.168.1.5:80"), entries: []))
    }

    // MARK: Confirmation timing

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let r1 = ServeConfig.parse(Data("""
    {"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3456"}}}}}
    """.utf8))[0]

    private func feed(_ a: inout ServeRouteAuditor, _ r: ServeRoute, _ l: BackendLiveness, _ s: TimeInterval) {
        a.record(routes: [r], results: [r: l], at: at(s))
    }

    func testDeadForUnder60SecondsIsNotConfirmed() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 30)
        XCTAssertTrue(a.confirmed.isEmpty)
    }

    func testDeadForExactly60SecondsConfirmsWithFirstDeadAsNoticedAt() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 60)
        XCTAssertEqual(a.confirmed.map(\.route), [r1])
        XCTAssertEqual(a.confirmed.first?.noticedAt, at(0))
    }

    func testSingleEvaluationNeverConfirms() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0)
        XCTAssertTrue(a.confirmed.isEmpty)
    }

    func testConfirmedStaysConfirmedWithFurtherDead() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 60); feed(&a, r1, .dead, 90)
        XCTAssertEqual(a.confirmed.first?.noticedAt, at(0))
    }

    func testAliveInterruptionRestartsTheTimer() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .alive, 30); feed(&a, r1, .dead, 60); feed(&a, r1, .dead, 90)
        XCTAssertTrue(a.confirmed.isEmpty)
        feed(&a, r1, .dead, 120)
        XCTAssertEqual(a.confirmed.first?.noticedAt, at(60))
    }

    func testUnknownResetsTimerAndNoticedAtIsStreakStart() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .unknown, 30); feed(&a, r1, .dead, 60)
        XCTAssertTrue(a.confirmed.isEmpty)
        feed(&a, r1, .dead, 120)
        XCTAssertEqual(a.confirmed.first?.noticedAt, at(60))
    }

    func testMissingResultCountsAsUnknown() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0)
        a.record(routes: [r1], results: [:], at: at(30))
        feed(&a, r1, .dead, 60)
        XCTAssertTrue(a.confirmed.isEmpty)
    }

    func testRouteRemovedFromConfigClearsFindingAndPendingTimer() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 60)
        a.record(routes: [], results: [:], at: at(70))
        XCTAssertTrue(a.confirmed.isEmpty)
        feed(&a, r1, .dead, 80)
        feed(&a, r1, .dead, 100)
        XCTAssertTrue(a.confirmed.isEmpty, "timer must restart at 80, not resume from 0")
    }

    func testChangedTargetClearsFindingAndStartsNewTimer() {
        let r2 = ServeConfig.parse(Data("""
        {"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3457"}}}}}
        """.utf8))[0]
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 60)
        feed(&a, r2, .dead, 70)
        XCTAssertTrue(a.confirmed.isEmpty)
        feed(&a, r2, .dead, 130)
        XCTAssertEqual(a.confirmed.map(\.route), [r2])
        XCTAssertEqual(a.confirmed.first?.noticedAt, at(70))
    }

    func testClockGoingBackwardsCountsAsZeroSpan() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 100); feed(&a, r1, .dead, 0)
        XCTAssertTrue(a.confirmed.isEmpty)
        feed(&a, r1, .dead, 160)
        XCTAssertEqual(a.confirmed.count, 1, "60s of forward time since first dead")
    }

    func testClockBackwardsSpanNeverConfirmsEvenWithManyEvaluations() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 1000); feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 10)
        XCTAssertTrue(a.confirmed.isEmpty)
    }

    func testLongSleepBetweenTwoDeadEvaluationsConfirms() {
        var a = ServeRouteAuditor()
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 8 * 3600)
        XCTAssertEqual(a.confirmed.count, 1)
    }

    func testCustomConfirmAfterIsHonoured() {
        var a = ServeRouteAuditor(confirmAfter: 10)
        feed(&a, r1, .dead, 0); feed(&a, r1, .dead, 10)
        XCTAssertEqual(a.confirmed.count, 1)
    }

    func testConfirmedFindingsSortedByPortThenPath() {
        let json = Data("""
        {"TCP":{"9000":{"HTTPS":true},"443":{"HTTPS":true}},"Web":{
        "fixture.tailnet.ts.net:9000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}},
        "fixture.tailnet.ts.net:443":{"Handlers":{"/b":{"Proxy":"http://127.0.0.1:2"},"/a":{"Proxy":"http://127.0.0.1:3"}}}}}
        """.utf8)
        let routes = ServeConfig.parse(json)
        let dead = Dictionary(uniqueKeysWithValues: routes.map { ($0, BackendLiveness.dead) })
        var a = ServeRouteAuditor()
        a.record(routes: routes, results: dead, at: at(0))
        a.record(routes: routes, results: dead, at: at(60))
        XCTAssertEqual(a.confirmed.map { "\($0.route.port)\($0.route.path ?? "")" }, ["443/a", "443/b", "9000/"])
    }

    func testRoutesTrackedIndependently() {
        let json = Data("""
        {"TCP":{"443":{"HTTPS":true}},"Web":{"fixture.tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"},"/api":{"Proxy":"http://127.0.0.1:2"}}}}}
        """.utf8)
        let routes = ServeConfig.parse(json)
        var a = ServeRouteAuditor()
        a.record(routes: routes, results: [routes[0]: .dead, routes[1]: .dead], at: at(0))
        a.record(routes: routes, results: [routes[0]: .dead, routes[1]: .alive], at: at(60))
        XCTAssertEqual(a.confirmed.map(\.route), [routes[0]])
    }

    // MARK: Removal command

    private let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    /// A bare `serve --https=<port> off` deletes every handler on the port (verified on
    /// Tailscale 1.104.4: it prompts "delete 2 handlers under port 9443?"). The root route
    /// must name `/` so a live sibling such as `/api` survives.
    func testHTTPSRootRouteRemovalNamesRootPathSoSiblingsSurvive() {
        XCTAssertEqual(route("http://127.0.0.1:3456").removalCommand, "\(cli) serve --https=8443 --set-path=/ off")
    }

    func testMountPathRemovalAddsSetPathBeforeOff() {
        let r = ServeConfig.parse(webJSON(port: 443, handlers: proxy("http://127.0.0.1:1", path: "/api")))[0]
        XCTAssertEqual(r.removalCommand, "\(cli) serve --https=443 --set-path=/api off")
    }

    func testTCPRemovalUsesTcpFlag() {
        let r = ServeConfig.parse(Data("{\"TCP\":{\"5432\":{\"TCPForward\":\"127.0.0.1:15432\"}}}".utf8))[0]
        XCTAssertEqual(r.removalCommand, "\(cli) serve --tcp=5432 off")
    }

    func testHTTPRemovalUsesHttpFlagAndNamesRootPath() {
        let r = ServeConfig.parse(webJSON(port: 80, tcp: "{\"HTTP\":true}", handlers: proxy("http://127.0.0.1:3000")))[0]
        XCTAssertEqual(r.removalCommand, "\(cli) serve --http=80 --set-path=/ off")
    }

    // MARK: Quoting, display strings

    private func mounted(_ path: String?, port: UInt16 = 443, funnel: Bool = false) -> ServeRoute {
        ServeRoute(port: port, kind: .https, path: path, target: "http://127.0.0.1:1",
                   backend: .loopback(host: "127.0.0.1", port: 1), funnel: funnel)
    }

    // Bug caught: a mount path with a space splits into two shell words when pasted.
    func testPathWithSpaceIsSingleQuoted() {
        XCTAssertEqual(mounted("/my app").removalCommand, "\(cli) serve --https=443 --set-path='/my app' off")
    }

    // Bug caught: an embedded apostrophe ends the quoting early.
    func testPathWithApostropheEscapesQuote() {
        XCTAssertEqual(mounted("/a'b").removalCommand, "\(cli) serve --https=443 --set-path='/a'\\''b' off")
    }

    // Bug caught: a crafted mount path runs a command when the user pastes the suggestion.
    func testPathWithCommandSubstitutionIsFullyQuoted() {
        XCTAssertEqual(mounted("/$(rm -rf ~)").removalCommand, "\(cli) serve --https=443 --set-path='/$(rm -rf ~)' off")
    }

    // Bug caught: over-quoting plain paths makes every command noisy.
    func testPlainPathStaysUnquoted() {
        XCTAssertEqual(mounted("/api").removalCommand, "\(cli) serve --https=443 --set-path=/api off")
    }

    // Bug caught: the two CLI path copies drift apart.
    func testRemovalCommandUsesTailscaleCLIPath() {
        XCTAssertTrue(mounted(nil).removalCommand.hasPrefix(TailscaleServeReader.cliPath + " "))
    }

    // Bug caught: nil or "/" path rendered as "nil" or a doubled slash in the label.
    func testDisplayPathHidesRootAndNil() {
        XCTAssertEqual(mounted(nil).displayPath, "")
        XCTAssertEqual(mounted("/").displayPath, "")
        XCTAssertEqual(mounted("/api").displayPath, "/api")
    }

    private func link(_ target: String, port: UInt16, backendPort: UInt16, path: String? = "/", funnel: Bool = false) -> ServeRoute {
        ServeRoute(port: port, kind: .https, path: path, target: target,
                   backend: .loopback(host: "127.0.0.1", port: backendPort), funnel: funnel)
    }

    // Bug caught: a self-loop reads like a typo instead of saying Tailscale points at itself.
    func testProblemDescriptionSelfLoop() {
        XCTAssertEqual(link("http://127.0.0.1:4392", port: 4392, backendPort: 4392).problemDescription,
                       "→ loops back to Tailscale itself")
    }

    // Bug caught: port formatted with a locale separator ("3,456") or wrong port shown.
    func testProblemDescriptionNormalAndLocalhost() {
        XCTAssertEqual(link("http://127.0.0.1:3456", port: 8443, backendPort: 3456).problemDescription,
                       "→ port 3456, nothing there")
        XCTAssertEqual(link("http://localhost:3456", port: 8443, backendPort: 3456).problemDescription,
                       "→ port 3456, nothing there")
    }

    // Bug caught: non-checkable routes crash or print an empty reason.
    func testProblemDescriptionNotCheckableShowsTarget() {
        let r = ServeRoute(port: 443, kind: .https, path: "/", target: "unix:/tmp/s.sock",
                           backend: .notCheckable, funnel: false)
        XCTAssertEqual(r.problemDescription, "→ unix:/tmp/s.sock")
    }

    // Bug caught: selector label drops the mount path or formats the port with a separator.
    func testSelectorLabelIncludesPortAndPath() {
        XCTAssertEqual(link("http://127.0.0.1:3456", port: 8443, backendPort: 3456).selectorLabel, ":8443")
        XCTAssertEqual(link("http://127.0.0.1:3456", port: 8443, backendPort: 3456, path: "/api").selectorLabel, ":8443/api")
        XCTAssertEqual(link("http://127.0.0.1:3456", port: 8443, backendPort: 3456, path: nil).selectorLabel, ":8443")
    }

    // Bug caught: the tooltip says "ago ago", drops the since-launch caveat, or omits Funnel.
    func testHelpTextReadsNaturallyWithAndWithoutFunnel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let noticed = now.addingTimeInterval(-120)
        let plain = ServeRouteFinding(route: link("http://127.0.0.1:3456", port: 8443, backendPort: 3456), noticedAt: noticed)
            .helpText(relativeTo: now)
        let funnel = ServeRouteFinding(route: link("http://127.0.0.1:3456", port: 8443, backendPort: 3456, funnel: true), noticedAt: noticed)
            .helpText(relativeTo: now)
        let expected = "Tailscale link → port 3456, nothing there · flagged 2 minutes ago (since Port Pilot started)"
        XCTAssertEqual(plain, expected)
        XCTAssertEqual(funnel, expected + " · Funnel (public)")
    }

    // Bug caught: a just-flagged link reads "in 0 seconds ago".
    func testHelpTextJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = ServeRouteFinding(route: link("http://127.0.0.1:3456", port: 8443, backendPort: 3456), noticedAt: now)
            .helpText(relativeTo: now)
        XCTAssertEqual(text, "Tailscale link → port 3456, nothing there · flagged just now (since Port Pilot started)")
    }

    // Bug caught: "1 links are broken" grammar.
    func testSummaryTitleSingularPlural() {
        XCTAssertEqual(ServeFindingsSummary.title(count: 1), "1 Tailscale link is broken")
        XCTAssertEqual(ServeFindingsSummary.title(count: 3), "3 Tailscale links are broken")
    }

    func testSummaryExplanation() {
        XCTAssertEqual(ServeFindingsSummary.explanation,
                       "Tailnet devices get an error at these addresses because nothing is running behind them.")
    }

    // Bug caught: unchecked suffix shown at 0 or pluralised wrongly.
    func testSummaryFootnoteUnchecked() {
        let base = "Copy fix copies a Terminal command that removes the link. Port Pilot never runs it."
        XCTAssertEqual(ServeFindingsSummary.footnote(unchecked: 0), base)
        XCTAssertEqual(ServeFindingsSummary.footnote(unchecked: 1), base + " +1 more link not checked.")
        XCTAssertEqual(ServeFindingsSummary.footnote(unchecked: 3), base + " +3 more links not checked.")
    }
}
