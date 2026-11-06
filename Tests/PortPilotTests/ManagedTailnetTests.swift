import XCTest
import Foundation
@testable import PortPilotCore

final class ManagedTailnetTests: XCTestCase {
    private func configuration(proxy: String = "http://127.0.0.1:20001", funnel: Bool = false, extraHandler: Bool = false, unrelated: String = "old") throws -> Data {
        var handlers: [String: Any] = ["/": ["Proxy": proxy]]
        if extraHandler { handlers["/other"] = ["Proxy": "http://127.0.0.1:9999"] }
        return try JSONSerialization.data(withJSONObject: [
            "TCP": ["443": ["HTTPS": true]],
            "Web": ["fixture.tailnet.ts.net:443": ["Handlers": handlers], "unrelated:8443": ["note": unrelated]],
            "AllowFunnel": ["fixture.tailnet.ts.net:443": funnel]])
    }
    func testOnlyStableLoopbackHTTPSWithoutFunnelCanBeAdopted() throws {
        let route = try ManagedTailnet.inspect(configuration(), selector: "fixture.tailnet.ts.net:443", stablePort: 20001)
        XCTAssertTrue(route.verified)
        XCTAssertEqual(route.endpoint, "https://fixture.tailnet.ts.net:443")
        for target in ["http://127.0.0.1:30001", "http://0.0.0.0:20001", "https://example.com", "http://127.0.0.1:20001/path"] {
            XCTAssertThrowsError(try ManagedTailnet.inspect(configuration(proxy: target), selector: route.selector, stablePort: 20001))
        }
        XCTAssertThrowsError(try ManagedTailnet.inspect(configuration(funnel: true), selector: route.selector, stablePort: 20001))
        XCTAssertThrowsError(try ManagedTailnet.inspect(configuration(extraHandler: true), selector: route.selector, stablePort: 20001))
        XCTAssertThrowsError(try ManagedTailnet.inspect(configuration(), selector: "fixture.tailnet.ts.net:444", stablePort: 20001))
    }
    func testUnrelatedRouteChangesDoNotAffectOwnedFingerprint() throws {
        let first = try ManagedTailnet.inspect(configuration(), selector: "fixture.tailnet.ts.net:443", stablePort: 20001)
        let second = try ManagedTailnet.inspect(configuration(unrelated: "changed"), selector: first.selector, stablePort: 20001)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }
}
