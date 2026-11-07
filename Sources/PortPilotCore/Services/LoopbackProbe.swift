import Darwin
import Foundation

/// The only addresses the probe may ever connect to. An enum (not a string)
/// makes the loopback-only guarantee structural.
public enum LoopbackAddress: String, Sendable, CaseIterable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"
}

/// Non-blocking TCP connect probe against loopback addresses.
/// Only ECONNREFUSED is `.dead`; timeouts and every other error are `.unknown`.
public enum LoopbackProbe {
    /// Non-blocking TCP connect to one loopback address. Never connects anywhere else.
    public static func probe(
        _ address: LoopbackAddress, port: UInt16, timeout: TimeInterval = 0.5
    ) async -> BackendLiveness {
        guard port != 0, !Task.isCancelled else { return .unknown }
        // Blocking poll() runs on a dedicated queue so it never occupies a cooperative-pool thread.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<BackendLiveness, Never>) in
            queue.async { continuation.resume(returning: connectOnce(address, port: port, timeout: timeout)) }
        }
        return Task.isCancelled ? .unknown : result
    }

    private static let queue = DispatchQueue(label: "PortPilot.LoopbackProbe", qos: .utility, attributes: .concurrent)

    /// Maps a serve backend host to loopback addresses and combines the results:
    /// any alive -> alive; all dead -> dead; otherwise unknown.
    /// Hosts other than loopback names are `.unknown` with no connect attempt.
    public static func probe(
        host: String, port: UInt16, timeout: TimeInterval = 0.5
    ) async -> BackendLiveness {
        guard port != 0 else { return .unknown }
        let addresses: [LoopbackAddress]
        switch host {
        case "127.0.0.1", "0.0.0.0": addresses = [.ipv4]
        case "::1": addresses = [.ipv6]
        case "localhost": addresses = [.ipv4, .ipv6]
        default: return .unknown
        }
        let results = await withTaskGroup(of: BackendLiveness.self) { group in
            for address in addresses {
                group.addTask { await probe(address, port: port, timeout: timeout) }
            }
            return await group.reduce(into: [BackendLiveness]()) { $0.append($1) }
        }
        if results.contains(.alive) { return .alive }
        if results.allSatisfy({ $0 == .dead }) { return .dead }
        return .unknown
    }

    // MARK: - Blocking connect (call off the caller's actor)

    private static func connectOnce(
        _ address: LoopbackAddress, port: UInt16, timeout: TimeInterval
    ) -> BackendLiveness {
        let family = address == .ipv4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return .unknown }

        let (rc, connectErrno) = withSockaddr(address, port: port) { ptr, len -> (Int32, Int32) in
            let rc = Darwin.connect(fd, ptr, len)
            return (rc, errno)
        }
        if rc == 0 { return .alive }
        if connectErrno == ECONNREFUSED { return .dead }
        guard connectErrno == EINPROGRESS else { return .unknown }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            let remainingMs = Int32(max(0, min(deadline.timeIntervalSinceNow * 1000, Double(Int32.max))).rounded(.up))
            let polled = poll(&pfd, 1, remainingMs)
            if polled > 0 { break }
            if polled == 0 { return .unknown }
            if errno != EINTR { return .unknown }
            if deadline.timeIntervalSinceNow <= 0 { return .unknown }
        }

        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0 else { return .unknown }
        switch soError {
        case 0: return .alive
        case ECONNREFUSED: return .dead
        default: return .unknown
        }
    }

    /// The single place a `sockaddr` is built. Values live on the stack; no manual allocation.
    private static func withSockaddr<T>(
        _ address: LoopbackAddress, port: UInt16,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        switch address {
        case .ipv4:
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6:
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }
}
