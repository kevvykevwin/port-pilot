import Foundation
import Darwin

/// A bounded byte-stream relay. Reads pause while a single 64 KiB chunk is
/// awaiting delivery; write notifications run only while the socket blocks.
public final class ManagedForwarder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.portpilot.forwarder")
    private static let queueKey = DispatchSpecificKey<String>()
    private let queueID = UUID().uuidString
    private let listenerFD: Int32
    private let listener: DispatchSourceRead
    private var stopped = false
    private var backend: UInt16
    private var generation = 1
    private var pairs: [UUID: Pair] = [:]

    private final class Flow {
        let source: Int32
        let destination: Int32
        let reader: DispatchSourceRead
        let writer: DispatchSourceWrite
        var reading = false
        var writing = false
        var eof = false
        var done = false
        var bytes = Data()
        var offset = 0
        init(source: Int32, destination: Int32, queue: DispatchQueue) {
            self.source = source; self.destination = destination
            reader = DispatchSource.makeReadSource(fileDescriptor: source, queue: queue)
            writer = DispatchSource.makeWriteSource(fileDescriptor: destination, queue: queue)
        }
        func readEnabled(_ enabled: Bool) {
            guard reading != enabled else { return }
            reading = enabled
            if enabled { reader.resume() } else { reader.suspend() }
        }
        func writeEnabled(_ enabled: Bool) {
            guard writing != enabled else { return }
            writing = enabled
            if enabled { writer.resume() } else { writer.suspend() }
        }
        func cancel() {
            reader.cancel(); writer.cancel()
            // Suspended sources must be resumed before their final release.
            if !reading { reader.resume(); reading = true }
            if !writing { writer.resume(); writing = true }
        }
    }
    private final class Pair {
        let client: Int32
        let server: Int32
        let generation: Int
        let upstream: Flow
        let downstream: Flow
        var connecting: Bool
        init(client: Int32, server: Int32, generation: Int, connecting: Bool, queue: DispatchQueue) {
            self.client = client; self.server = server; self.generation = generation; self.connecting = connecting
            upstream = Flow(source: client, destination: server, queue: queue)
            downstream = Flow(source: server, destination: client, queue: queue)
            let clientLease = ManagedFDLease(client, count: 2), serverLease = ManagedFDLease(server, count: 2)
            upstream.reader.setCancelHandler { clientLease.release() }
            downstream.writer.setCancelHandler { clientLease.release() }
            downstream.reader.setCancelHandler { serverLease.release() }
            upstream.writer.setCancelHandler { serverLease.release() }
        }
    }
    public init(stablePort: UInt16, backendPort: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagedError.portUnavailable }
        ManagedSocket.configure(fd)
        // Rebind the published port after helper restart despite TIME_WAIT
        // connections. SO_REUSEPORT remains off: a live listener still wins.
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.address(stablePort)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 128) == 0 else { Darwin.close(fd); throw ManagedError.portUnavailable }
        listenerFD = fd; backend = backendPort
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setCancelHandler { Darwin.close(fd) }
        queue.setSpecific(key: Self.queueKey, value: queueID)
        listener.setEventHandler { [weak self] in self?.accept() }
        listener.resume()
    }
    deinit { stop() }
    private func serialized(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID { body() }
        else { queue.sync(execute: body) }
    }
    public func switchBackend(to port: UInt16, generation: Int) {
        serialized { backend = port; self.generation = generation }
    }
    public func connectionCount(generation: Int) -> Int {
        var count = 0
        serialized { count = pairs.values.filter { $0.generation == generation }.count }
        return count
    }
    public func stop() {
        serialized {
            guard !stopped else { return }
            stopped = true; listener.cancel()
            for id in Array(pairs.keys) { closePair(id) }
        }
    }
    private static func address(_ port: UInt16) -> sockaddr_in {
        var result = sockaddr_in()
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); result.sin_family = sa_family_t(AF_INET)
        result.sin_addr.s_addr = inet_addr("127.0.0.1"); result.sin_port = port.bigEndian
        return result
    }
    private func accept() {
        guard !stopped else { return }
        // Bound each callback so existing streams get a turn during a flood.
        for _ in 0..<32 {
            let client = Darwin.accept(listenerFD, nil, nil)
            if client < 0 { return }
            guard ManagedConnectionBudget.shared.acquire() else { Darwin.close(client); continue }
            ManagedSocket.configure(client)
            let server = socket(AF_INET, SOCK_STREAM, 0)
            guard server >= 0 else { Darwin.close(client); ManagedConnectionBudget.shared.release(); continue }
            ManagedSocket.configure(server)
            var address = Self.address(backend)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 || errno == EINPROGRESS else {
                Darwin.close(client); Darwin.close(server); ManagedConnectionBudget.shared.release(); continue
            }
            let id = UUID(), pair = Pair(client: client, server: server, generation: generation, connecting: result != 0, queue: queue)
            pairs[id] = pair
            pair.upstream.reader.setEventHandler { [weak self] in self?.read(id, upstream: true) }
            pair.downstream.reader.setEventHandler { [weak self] in self?.read(id, upstream: false) }
            pair.upstream.writer.setEventHandler { [weak self] in self?.write(id, upstream: true) }
            pair.downstream.writer.setEventHandler { [weak self] in self?.write(id, upstream: false) }
            if pair.connecting { pair.upstream.writeEnabled(true) }
            else { pair.upstream.readEnabled(true); pair.downstream.readEnabled(true) }
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.pairs[id]?.connecting == true else { return }
                self.closePair(id)
            }
        }
    }
    private func read(_ id: UUID, upstream: Bool) {
        guard let pair = pairs[id], !pair.connecting else { return }
        let flow = upstream ? pair.upstream : pair.downstream
        guard !flow.eof, flow.bytes.isEmpty else { return }
        var bytes = Data(count: 65_536)
        let count = bytes.withUnsafeMutableBytes { recv(flow.source, $0.baseAddress, $0.count, 0) }
        if count < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { closePair(id) }
            return
        }
        flow.readEnabled(false)
        if count == 0 { flow.eof = true }
        else { bytes.count = count; flow.bytes = bytes; flow.offset = 0 }
        write(id, upstream: upstream)
    }
    private func write(_ id: UUID, upstream: Bool) {
        guard let pair = pairs[id] else { return }
        let flow = upstream ? pair.upstream : pair.downstream
        if pair.connecting {
            guard upstream else { return }
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(pair.server, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { closePair(id); return }
            pair.connecting = false
            flow.writeEnabled(false)
            pair.upstream.readEnabled(true); pair.downstream.readEnabled(true)
            return
        }
        while flow.offset < flow.bytes.count {
            let count = flow.bytes.withUnsafeBytes { send(flow.destination, $0.baseAddress!.advanced(by: flow.offset), $0.count - flow.offset, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { flow.writeEnabled(true); return }
                closePair(id); return
            }
            guard count > 0 else { closePair(id); return }
            flow.offset += count
        }
        flow.bytes = Data(); flow.offset = 0; flow.writeEnabled(false)
        if flow.eof {
            _ = shutdown(flow.destination, SHUT_WR)
            flow.done = true
            if pair.upstream.done && pair.downstream.done { closePair(id) }
        } else { flow.readEnabled(true) }
    }
    private func closePair(_ id: UUID) {
        guard let pair = pairs.removeValue(forKey: id) else { return }
        pair.upstream.cancel(); pair.downstream.cancel()
        ManagedConnectionBudget.shared.release()
    }
}

/// Closing only after both sources have cancelled avoids descriptor-reuse races
/// with dispatch's asynchronous kernel-event deregistration.
private final class ManagedFDLease: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    private var count: Int
    init(_ fd: Int32, count: Int) { self.fd = fd; self.count = count }
    func release() { lock.withLock { count -= 1; if count == 0 { Darwin.close(fd) } } }
}

private final class ManagedConnectionBudget: @unchecked Sendable {
    static let shared = ManagedConnectionBudget()
    private let lock = NSLock()
    private var count = 0
    func acquire() -> Bool {
        lock.withLock { guard count < 200 else { return false }; count += 1; return true }
    }
    func release() { lock.withLock { count -= 1 } }
}
