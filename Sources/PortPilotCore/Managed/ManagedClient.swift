import Foundation
import Darwin

public struct ManagedServiceReport: Codable, Sendable, Identifiable {
    public var id: UUID
    public var workspace: ManagedWorkspace
    public var name: String
    public var variant: String
    public var revision: Int
    public var lifecycle: String
    public var claims: [ManagedClaim]
    public var keepRunning: Bool
    public var incarnations: [ManagedIncarnation]
    public var backendPort: UInt16?
    public var stablePort: UInt16?
    public var routeGeneration: Int
    public var fence: UUID?
    public var treeComplete: Bool
    public var tailnet: ManagedTailnetRoute?
    public var transition: ManagedRouteTransition?
    public var proxyIncarnation: ManagedIncarnation?
    public var activeClaims: [ManagedClaim] { claims.filter(\.active) }
}

public struct ManagedListenerAssociation: Sendable, Equatable {
    public var serviceId: UUID
    public var label: String
    public static func match(_ entry: PortEntry, reports: [ManagedServiceReport]) -> Self? {
        for service in reports {
            let proxy = service.proxyIncarnation
            if entry.port == service.stablePort, entry.pid == proxy?.pid, entry.processStartTime == proxy?.startTime {
                return Self(serviceId: service.id, label: "\(service.name) · stable preview")
            }
            if service.incarnations.contains(where: { $0.pid == entry.pid && $0.startTime == entry.processStartTime }) {
                if entry.port == service.backendPort { return Self(serviceId: service.id, label: "\(service.name) · backend") }
                return Self(serviceId: service.id, label: "\(service.name) · managed process")
            }
        }
        return nil
    }
}

public struct ManagedClient: Sendable {
    public var root: URL
    public var credentialFile: URL
    public init(root: URL = ManagedPersistence.defaultRoot, credentialFile: URL? = nil) {
        self.root = root; self.credentialFile = credentialFile ?? root.appendingPathComponent("gui-credential.json")
    }
    /// Reads a small credential file only if it is a private regular file owned by this user.
    static func readPrivateFile(_ file: URL, limit: Int = 4096) throws -> Data {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= limit else { throw ManagedError.unauthorized }
        return try Data(contentsOf: file)
    }
    public func request(operation: String, revision: Int? = nil, payload: [String: ManagedJSON] = [:]) throws -> ManagedResponse {
        let data = try Self.readPrivateFile(credentialFile)
        let auth = try JSONDecoder().decode([String: String].self, from: data)
        guard let actor = auth["actor"], let credential = auth["credential"] else { throw ManagedError.unauthorized }
        let request = ManagedRequest(operation: operation, actor: actor, credential: credential, expectedRevision: revision, payload: payload)
        return try ManagedSocket.request(request, path: root.appendingPathComponent("control.sock").path)
    }
    public func services() throws -> [ManagedServiceReport] {
        try records(operation: "services.list", type: ManagedServiceReport.self)
    }
    public func operations() throws -> [ManagedOperation] {
        try records(operation: "operations.list", type: ManagedOperation.self)
    }
    public func actor() throws -> String {
        let response = try request(operation: "status")
        if let error = response.error { throw error }
        guard case .object(let status) = response.data, let actor = status["actor"]?.string else { throw ManagedError.invalidInput }
        return actor
    }
    private func records<T: Decodable>(operation: String, type: T.Type) throws -> [T] {
        var records: [T] = []; var cursor: String?
        repeat {
            let response = try request(operation: operation, payload: cursor.map { ["cursor": .string($0)] } ?? [:])
            if let error = response.error { throw error }
            guard case .object(let page) = response.data, case .array(let values) = page["records"] else { throw ManagedError.invalidInput }
            records += try values.map { try JSONDecoder().decode(T.self, from: JSONEncoder().encode($0)) }
            cursor = page["cursor"]?.string
            guard records.count <= 10_000 else { throw ManagedError.recordTooLarge }
        } while cursor != nil
        return records
    }
}

extension ManagedSocket {
    /// Same transport as `request(_:path:)` but returns the raw response bytes, so callers can run
    /// `ManagedWire.requireUniqueKeys` and strict type checks before any lossy decoding.
    static func requestRaw(_ request: ManagedRequest, path: String) throws -> Data {
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
        return try receive(fd, limit: ManagedWire.responseLimit, deadline: ProcessInfo.processInfo.systemUptime + 5)
    }
}
