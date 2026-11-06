import Foundation
import Darwin

/// JSONDecoder accepts duplicate keys. Check the wire grammar first, including
/// escaped spellings of a key, so authorization never depends on parser choice.
public enum ManagedWire {
    public static let requestLimit = 65_536
    public static let responseLimit = 1_048_576
    public static func decode(_ data: Data) throws -> ManagedRequest {
        guard !data.isEmpty, data.count <= requestLimit, String(data: data, encoding: .utf8) != nil else {
            throw ManagedError.invalidInput
        }
        try requireUniqueKeys(data)
        let request: ManagedRequest
        do { request = try JSONDecoder().decode(ManagedRequest.self, from: data) }
        catch { throw ManagedError.invalidInput }
        guard request.protocolVersion == 1 else { throw ManagedError.protocolMismatch }
        guard !request.requestId.isEmpty, request.requestId.utf8.count <= 128,
              !request.actor.isEmpty, request.actor.utf8.count <= 256,
              request.credential.utf8.count <= 256 else { throw ManagedError.invalidInput }
        return request
    }
    /// Rejects invalid UTF-8, malformed JSON and duplicate object keys (including
    /// escaped spellings). Shared by request decoding and the receiver contract so
    /// there is one grammar checker.
    public static func requireUniqueKeys(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw ManagedError.invalidInput }
        var parser = UniqueJSON(bytes: Array(data)); try parser.document()
    }
    public static func frame(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }; result.append(data); return result
    }
}

private struct UniqueJSON {
    var bytes: [UInt8]; var index = 0
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        space(); guard index < bytes.count, bytes[index] == byte else { throw ManagedError.invalidInput }; index += 1
    }
    mutating func string() throws -> String {
        space(); let start = index; try consume(34)
        while index < bytes.count {
            let c = bytes[index]; index += 1
            if c == 92 { guard index < bytes.count else { throw ManagedError.invalidInput }; index += 1 }
            else if c == 34 {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw ManagedError.invalidInput }
                return value
            }
        }
        throw ManagedError.invalidInput
    }
    mutating func document() throws { try value(depth: 0); space(); guard index == bytes.count else { throw ManagedError.invalidInput } }
    mutating func value(depth: Int) throws {
        space(); guard depth < 32, index < bytes.count else { throw ManagedError.invalidInput }
        switch bytes[index] {
        case 123:
            index += 1; space(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                let key = try string(); guard keys.insert(key).inserted else { throw ManagedError.invalidInput }
                try consume(58); try value(depth: depth + 1); space()
                guard index < bytes.count else { throw ManagedError.invalidInput }
                if bytes[index] == 125 { index += 1; return }; try consume(44)
            }
        case 91:
            index += 1; space()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); space(); guard index < bytes.count else { throw ManagedError.invalidInput }
                if bytes[index] == 93 { index += 1; return }; try consume(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start,
                  (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) != nil else {
                throw ManagedError.invalidInput
            }
        }
    }
}

public enum ManagedSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ManagedError.invalidInput }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    }
    static func wait(_ fd: Int32, event: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ManagedError.dependencyUnavailable }
            var p = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&p, 1, Int32(min(remaining * 1000 + 1, 5000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, p.revents & event != 0 else { throw ManagedError.dependencyUnavailable }; return
        }
    }
    static func read(_ fd: Int32, count: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count); var offset = 0
        while offset < count {
            try wait(fd, event: Int16(POLLIN), deadline: deadline)
            let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if n < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard n > 0 else { throw ManagedError.dependencyUnavailable }; offset += n
        }
        return data
    }
    static func receive(_ fd: Int32, limit: Int, deadline: TimeInterval) throws -> Data {
        let header = try read(fd, count: 4, deadline: deadline)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length <= limit else { throw ManagedError.invalidInput }
        return try read(fd, count: length, deadline: deadline)
    }
    static func write(_ fd: Int32, data: Data, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, event: Int16(POLLOUT), deadline: deadline)
            let n = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if n < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard n > 0 else { throw ManagedError.dependencyUnavailable }; offset += n
        }
    }
    public static func request(_ request: ManagedRequest, path: String) throws -> ManagedResponse {
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= ManagedWire.requestLimit else { throw ManagedError.invalidInput }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw ManagedError.dependencyUnavailable }
        defer { close(fd) }; configure(fd)
        var address = try address(path)
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        if result != 0 {
            guard errno == EINPROGRESS else { throw ManagedError.dependencyUnavailable }
            try wait(fd, event: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw ManagedError.dependencyUnavailable }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw ManagedError.unauthorized }
        try write(fd, data: ManagedWire.frame(payload), deadline: deadline)
        return try JSONDecoder().decode(ManagedResponse.self, from: receive(fd, limit: ManagedWire.responseLimit, deadline: ProcessInfo.processInfo.systemUptime + 5))
    }
}

public final class ManagedSocketServer: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let slots = DispatchSemaphore(value: 32)
    /// The second argument is the peer's process identity read from the kernel (never from the payload);
    /// nil when the kernel or process table cannot resolve it.
    private let handler: @Sendable (ManagedRequest, ManagedIncarnation?) async -> ManagedResponse
    /// Caller must already hold the registry's exclusive writer lock.
    public init(path: String, handler: @escaping @Sendable (ManagedRequest, ManagedIncarnation?) async -> ManagedResponse) throws {
        self.path = path; self.handler = handler
        var address = try ManagedSocket.address(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw ManagedError.dependencyUnavailable }
        ManagedSocket.configure(fd)
        // Only remove a stale owned socket, never an arbitrary file.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { close(fd); throw ManagedError.unauthorized }
            unlink(path)
        }
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            close(fd); throw ManagedError.dependencyUnavailable
        }
    }
    deinit { close(fd); unlink(path) }
    public func run() throws {
        while true {
            do { try ManagedSocket.wait(fd, event: Int16(POLLIN), deadline: ProcessInfo.processInfo.systemUptime + 5) }
            catch { continue }
            let client = accept(fd, nil, nil); if client < 0 { continue }
            ManagedSocket.configure(client)
            let acceptedAt = ProcessInfo.processInfo.systemUptime
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            DispatchQueue.global().async { [self] in
                do {
                    var uid: uid_t = 0; var gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { throw ManagedError.unauthorized }
                    let peer = Self.peerIncarnation(client)
                    let data = try ManagedSocket.receive(client, limit: ManagedWire.requestLimit, deadline: acceptedAt + 5)
                    let request = try ManagedWire.decode(data)
                    Task {
                        let response = await handler(request, peer)
                        finish(client, response: response)
                    }
                } catch {
                    finish(client, response: ManagedResponse(requestId: nil, error: error as? ManagedError ?? .invalidInput))
                }
            }
        }
    }
    /// Kernel-reported peer PID (LOCAL_PEERPID) resolved to PID + start time. Read right after accept, while
    /// the connected peer is still the socket owner; nil if unavailable.
    static func peerIncarnation(_ client: Int32) -> ManagedIncarnation? {
        var pid: pid_t = 0; var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return ManagedProcess.incarnation(pid: pid)
    }
    private func finish(_ client: Int32, response: ManagedResponse) {
        defer { close(client); slots.signal() }
        guard var data = try? JSONEncoder().encode(response) else { return }
        if data.count > ManagedWire.responseLimit {
            data = (try? JSONEncoder().encode(ManagedResponse(requestId: response.requestId, error: .recordTooLarge))) ?? Data()
        }
        try? ManagedSocket.write(client, data: ManagedWire.frame(data), deadline: ProcessInfo.processInfo.systemUptime + 5)
    }
}
