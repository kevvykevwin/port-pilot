import Foundation

/// Where a Tailscale Serve route forwards to, as far as Port Pilot can check.
public enum ServeBackend: Sendable, Hashable {
    /// A loopback target. `host` is one of `127.0.0.1`, `localhost`, `::1`, `0.0.0.0`.
    case loopback(host: String, port: UInt16)
    /// Remote hosts, unix sockets, other loopback aliases, invalid ports.
    case notCheckable
}

/// One entry from `tailscale serve status --json`. Identity is the whole value,
/// so a changed target is a different route.
public struct ServeRoute: Sendable, Hashable {
    public enum Kind: String, Sendable { case https, http, tcp }

    /// Selector port (the port Tailscale listens on).
    public let port: UInt16
    public let kind: Kind
    /// Mount path; nil for TCP forwards.
    public let path: String?
    /// Raw `Proxy` / `TCPForward` string.
    public let target: String
    public let backend: ServeBackend
    public let funnel: Bool

    /// Mount path as shown to the user: empty for TCP forwards and the root mount.
    public var displayPath: String {
        guard let path, path != "/" else { return "" }
        return path
    }

    /// `:8443/api`
    public var selectorLabel: String { ":\(String(port))\(displayPath)" }

    /// Plain-language reason the link is broken, starting with an arrow.
    public var problemDescription: String {
        switch backend {
        case .loopback(_, let backendPort):
            return backendPort == port
                ? "→ loops back to Tailscale itself"
                : "→ port \(String(backendPort)), nothing there"
        case .notCheckable:
            return "→ \(target)"
        }
    }

    /// Command that removes only this route. Suggested to the user, never run.
    /// Web routes always name their path, including `/`: without `--set-path`,
    /// `serve --https=<port> off` deletes every handler on the port (Tailscale 1.104.4).
    public var removalCommand: String {
        var command = "\(Self.shellQuoted(TailscaleServeReader.cliPath)) serve --\(kind.rawValue)=\(port)"
        if let path { command += " --set-path=\(Self.shellQuoted(path))" }
        return command + " off"
    }

    /// POSIX single-quotes anything outside a conservative safe set; `'` becomes `'\''`.
    private static func shellQuoted(_ text: String) -> String {
        let safe = text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "/._~%-".unicodeScalars.contains(scalar))
        }
        if safe && !text.isEmpty { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public init(
        port: UInt16, kind: Kind, path: String?, target: String,
        backend: ServeBackend, funnel: Bool
    ) {
        self.port = port
        self.kind = kind
        self.path = path
        self.target = target
        self.backend = backend
        self.funnel = funnel
    }

    fileprivate static func ordered(_ a: ServeRoute, _ b: ServeRoute) -> Bool {
        (a.port, a.path ?? "", a.target) < (b.port, b.path ?? "", b.target)
    }
}

public enum ServeConfig {
    public static let maxBytes = 1_048_576

    /// Parses `serve status --json`. Never throws: oversized, malformed or
    /// unrecognised input yields `[]`. Sorted by (port, path).
    public static func parse(_ data: Data) -> [ServeRoute] {
        guard data.count <= maxBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        let tcp = root["TCP"] as? [String: Any] ?? [:]
        let funnel = root["AllowFunnel"] as? [String: Any] ?? [:]
        var routes: [ServeRoute] = []

        for (portKey, value) in tcp {
            guard let port = UInt16(portKey), let entry = value as? [String: Any],
                  let forward = entry["TCPForward"] as? String else { continue }
            routes.append(ServeRoute(
                port: port, kind: .tcp, path: nil, target: forward,
                backend: backend(authority: forward, defaultPort: nil), funnel: false))
        }

        let web = root["Web"] as? [String: Any] ?? [:]
        for (selector, value) in web {
            guard let port = selectorPort(selector),
                  let entry = tcp[String(port)] as? [String: Any],
                  let kind = webKind(entry),
                  let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any]
            else { continue }
            let isFunnel = funnel[selector] as? Bool == true
            for (path, handler) in handlers {
                guard let target = (handler as? [String: Any])?["Proxy"] as? String else { continue }
                routes.append(ServeRoute(
                    port: port, kind: kind, path: path, target: target,
                    backend: proxyBackend(target), funnel: isFunnel))
            }
        }
        return routes.sorted(by: ServeRoute.ordered)
    }

    private static func webKind(_ tcpEntry: [String: Any]) -> ServeRoute.Kind? {
        if tcpEntry["HTTPS"] as? Bool == true { return .https }
        if tcpEntry["HTTP"] as? Bool == true { return .http }
        return nil
    }

    /// `host:port` selector; the host may itself contain colons only for odd configs,
    /// so split on the last one.
    private static func selectorPort(_ selector: String) -> UInt16? {
        guard let colon = selector.lastIndex(of: ":") else { return nil }
        return UInt16(selector[selector.index(after: colon)...])
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]

    /// `scheme://host[:port][/...]`. Anything without `://` (e.g. `unix:`) or with an
    /// unknown scheme is not checkable.
    private static func proxyBackend(_ target: String) -> ServeBackend {
        guard let range = target.range(of: "://") else { return .notCheckable }
        let defaultPort: UInt16
        switch target[..<range.lowerBound].lowercased() {
        case "http": defaultPort = 80
        case "https", "https+insecure": defaultPort = 443
        default: return .notCheckable
        }
        return backend(authority: String(target[range.upperBound...]), defaultPort: defaultPort)
    }

    /// Parses `host[:port]` or `[v6][:port]`, ignoring any trailing path/query.
    /// `defaultPort == nil` means the port is mandatory (TCPForward).
    private static func backend(authority raw: String, defaultPort: UInt16?) -> ServeBackend {
        let authority = raw.prefix { !"/?#".contains($0) }
        guard !authority.contains("@") else { return .notCheckable }

        var host: String
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return .notCheckable }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return .notCheckable }
                portText = rest.dropFirst()
            }
        } else {
            let parts = authority.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return .notCheckable }  // bare IPv6 is ambiguous
            host = String(parts[0])
            if parts.count == 2 { portText = parts[1] }
        }

        host = host.lowercased()
        guard loopbackHosts.contains(host) else { return .notCheckable }

        let port: UInt16
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
                  let parsed = UInt16(portText), parsed != 0 else { return .notCheckable }
            port = parsed
        } else if let defaultPort {
            port = defaultPort
        } else {
            return .notCheckable
        }
        return .loopback(host: host, port: port)
    }
}

public enum ServeRouteMatcher {
    /// True when no non-Tailscale listener in `entries` could serve the route's loopback
    /// backend, so the route needs a connect probe. `.notCheckable` is never a candidate.
    public static func isCandidate(_ route: ServeRoute, entries: [PortEntry]) -> Bool {
        guard case let .loopback(host, port) = route.backend else { return false }
        let wantsIPv4 = host != "::1"
        let wantsIPv6 = host == "::1" || host == "localhost"

        return !entries.contains { entry in
            guard entry.state == .listen, entry.protocol == .tcp, entry.port == port,
                  !ProcessClassifier.isTailscaleServeListener(entry) else { return false }
            return (wantsIPv4 && serves(entry, ipv4: true)) || (wantsIPv6 && serves(entry, ipv4: false))
        }
    }

    /// An IPv6 wildcard is dual-stack, so it also serves IPv4 targets.
    private static func serves(_ entry: PortEntry, ipv4 target: Bool) -> Bool {
        switch (entry.family, target) {
        case (.ipv4, true): return ["127.0.0.1", "0.0.0.0", "*"].contains(entry.localAddress)
        case (.ipv6, true): return ["::", "*"].contains(entry.localAddress)
        case (.ipv6, false): return ["::1", "::", "*"].contains(entry.localAddress)
        case (.ipv4, false): return false
        }
    }
}

public struct ServeRouteFinding: Sendable, Hashable, Identifiable {
    public let route: ServeRoute
    public let noticedAt: Date
    public var id: ServeRoute { route }

    public init(route: ServeRoute, noticedAt: Date) {
        self.route = route
        self.noticedAt = noticedAt
    }

    /// Tooltip line for the Tailscale listener row.
    public func helpText(relativeTo now: Date) -> String {
        var text = "Tailscale link \(route.problemDescription) · flagged \(Self.relative(noticedAt, to: now)) (since Port Pilot started)"
        if route.funnel { text += " · Funnel (public)" }
        return text
    }

    /// "2 minutes ago", or "just now" under 5 s (the formatter would say "in 0 seconds").
    private static func relative(_ date: Date, to now: Date) -> String {
        guard now.timeIntervalSince(date) >= 5 else { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    // Formatting is thread-safe once configured; only read after this initializer.
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter
    }()
}

public enum ServeFindingsSummary {
    public static func title(count: Int) -> String {
        count == 1 ? "1 Tailscale link is broken" : "\(String(count)) Tailscale links are broken"
    }

    public static let explanation =
        "Tailnet devices get an error at these addresses because nothing is running behind them."

    public static func footnote(unchecked: Int) -> String {
        var text = "Copy fix copies a Terminal command that removes the link. Port Pilot never runs it."
        if unchecked > 0 {
            text += " +\(String(unchecked)) more \(unchecked == 1 ? "link" : "links") not checked."
        }
        return text
    }
}

/// Turns repeated liveness evaluations into confirmed findings: at least 2 dead
/// evaluations spanning at least `confirmAfter` seconds, with no alive/unknown between.
/// The caller must not call `record` for a failed port scan.
public struct ServeRouteAuditor: Sendable {
    private struct Streak: Sendable {
        let firstDead: Date
        var lastDead: Date
        var count: Int
    }

    public let confirmAfter: TimeInterval
    private var streaks: [ServeRoute: Streak] = [:]

    public init(confirmAfter: TimeInterval = 60) {
        self.confirmAfter = confirmAfter
    }

    /// `results` holds liveness per configured route; a missing entry counts as `.unknown`.
    /// Routes absent from `routes` are dropped.
    public mutating func record(
        routes: [ServeRoute], results: [ServeRoute: BackendLiveness], at now: Date
    ) {
        var next: [ServeRoute: Streak] = [:]
        for route in routes where (results[route] ?? .unknown) == .dead {
            if var streak = streaks[route] {
                streak.lastDead = now
                streak.count += 1
                next[route] = streak
            } else {
                next[route] = Streak(firstDead: now, lastDead: now, count: 1)
            }
        }
        streaks = next
    }

    public var confirmed: [ServeRouteFinding] {
        streaks
            .filter { _, streak in
                // A backwards clock yields a negative span, which counts as 0.
                streak.count >= 2 && max(0, streak.lastDead.timeIntervalSince(streak.firstDead)) >= confirmAfter
            }
            .map { ServeRouteFinding(route: $0.key, noticedAt: $0.value.firstDead) }
            .sorted { ServeRoute.ordered($0.route, $1.route) }
    }
}
