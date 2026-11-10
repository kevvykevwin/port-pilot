import Foundation
import Darwin

public struct ManagedLaunch: Codable, Sendable {
    public var service: String
    public var variant: String
    public var executable: String
    public var arguments: [String]
    public var cwd: String
    public var readinessPath: String
    public var readinessStatus: Int
    public var readinessMarker: String?
    public var configurationFiles: [String]
    public var parallelSafe: Bool
    public var portEnvironment: String?
    public var environment: [String: String]?
    public var secretReferences: [String: String]?

    public init(service: String, variant: String = "default", executable: String, arguments: [String], cwd: String,
                readinessPath: String = "/", readinessStatus: Int = 200, readinessMarker: String? = nil,
                configurationFiles: [String] = [], parallelSafe: Bool = false,
                portEnvironment: String? = nil, environment: [String: String] = [:], secretReferences: [String: String] = [:]) {
        self.service = service; self.variant = variant; self.executable = executable; self.arguments = arguments
        self.cwd = cwd; self.readinessPath = readinessPath; self.readinessStatus = readinessStatus
        self.readinessMarker = readinessMarker; self.configurationFiles = configurationFiles; self.parallelSafe = parallelSafe
        self.portEnvironment = portEnvironment; self.environment = environment; self.secretReferences = secretReferences
    }
    public func validate() throws {
        guard ManagedServiceName.isValid(service),
              ManagedServiceName.isValid(variant),
              executable.hasPrefix("/"), !executable.contains("\0"), FileManager.default.isExecutableFile(atPath: executable),
              cwd.hasPrefix("/"), !cwd.contains("\0"),
              arguments.filter({ $0 == "{port}" }).count + (portEnvironment == nil ? 0 : 1) == 1,
              !arguments.contains(where: { $0.contains("\0") }),
              readinessPath.hasPrefix("/"), !readinessPath.hasPrefix("//"), !readinessPath.contains("?"),
              !readinessPath.contains("#"), readinessPath.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }),
              URL(string: "http://127.0.0.1" + readinessPath)?.host == "127.0.0.1", (100...599).contains(readinessStatus),
              readinessMarker == nil || readinessMarker?.isEmpty == false else { throw ManagedError.invalidInput }
        let names = Array((environment ?? [:]).keys) + Array((secretReferences ?? [:]).keys) + (portEnvironment.map { [$0] } ?? [])
        guard Set(names).count == names.count, names.allSatisfy(Self.validEnvironmentName),
              (environment ?? [:]).values.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16_384 }),
              (secretReferences ?? [:]).values.allSatisfy(ManagedServiceName.isValid) else { throw ManagedError.invalidInput }
    }
    public static func validEnvironmentName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, (65...90).contains(first) || first == 95,
              bytes.count <= 128 else { return false }
        return bytes.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    public func resolvedEnvironment(port: UInt16, secret: (String) throws -> String) throws -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        for (name, value) in environment ?? [:] { result[name] = value }
        for (name, reference) in secretReferences ?? [:] { result[name] = try secret(reference) }
        if let portEnvironment { result[portEnvironment] = String(port) }
        return result
    }
    public func workspace() throws -> ManagedWorkspace {
        let startingPath = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        var checkout = URL(fileURLWithPath: startingPath)
        var gitRoot: URL?
        for _ in 0..<256 {
            if FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) { gitRoot = checkout; break }
            if checkout.path == "/" { break }
            checkout.deleteLastPathComponent()
        }
        let rootPath = gitRoot?.path ?? ProjectResolver().findProjectRoot(from: startingPath) ?? startingPath
        let canonical = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard stat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ManagedError.invalidInput }
        // Birth time prevents a recycled inode from silently identifying a new checkout.
        var identity = "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        if let gitRoot {
            var directory = gitRoot.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                let data = try ManagedBoundedFile.read(directory, limit: 4096)
                guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                      line.hasPrefix("gitdir: "), !line.contains("\0"), !line.contains("\n") else { throw ManagedError.needsDecision }
                directory = URL(fileURLWithPath: String(line.dropFirst(8)), relativeTo: gitRoot).standardizedFileURL
            }
            directory = directory.resolvingSymlinksInPath()
            var metadata = stat()
            guard stat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw ManagedError.needsDecision }
            identity += ":git:\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_birthtimespec.tv_sec):\(metadata.st_birthtimespec.tv_nsec)"
            let commonFile = directory.appendingPathComponent("commondir")
            if FileManager.default.fileExists(atPath: commonFile.path) {
                let bytes = try ManagedBoundedFile.read(commonFile, limit: 4096)
                guard let reference = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                      !reference.isEmpty, !reference.contains("\n"), !reference.contains("\0") else { throw ManagedError.needsDecision }
                let common = URL(fileURLWithPath: reference, relativeTo: directory).resolvingSymlinksInPath()
                guard stat(common.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw ManagedError.needsDecision }
                identity += ":common:\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_birthtimespec.tv_sec):\(metadata.st_birthtimespec.tv_nsec)"
            }
        }
        return ManagedWorkspace(id: UUID(), path: canonical.path, filesystemIdentity: identity)
    }
    public func fingerprint(key: Data, secret: (String) throws -> String = { _ in throw ManagedError.needsDecision }) throws -> String {
        var canonical = self
        canonical.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        canonical.cwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        var bytes = Data("declared-launch-adapter-v2".utf8)
        bytes.append(try ManagedDigest.canonical(canonical))
        for path in configurationFiles {
            guard path.hasPrefix("/") else { throw ManagedError.invalidInput }
            let data = try ManagedBoundedFile.read(URL(fileURLWithPath: path).resolvingSymlinksInPath(), limit: 10 * 1024 * 1024)
            bytes.append(Data(ManagedDigest.hash(data).utf8))
        }
        for name in (secretReferences ?? [:]).keys.sorted() {
            bytes.append(try ManagedDigest.canonical([name, secret(secretReferences![name]!)]))
        }
        return ManagedDigest.keyed(bytes, key: key)
    }
}

public enum ManagedProcess {
    public static func systemIdentity(_ name: String) -> String? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0, length < 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public static func incarnation(pid: Int32) -> ManagedIncarnation? {
        guard let boot = systemIdentity("kern.bootsessionuuid"), let host = systemIdentity("kern.uuid"),
              let start = LibProc.processStartTime(pid: pid) else { return nil }
        return ManagedIncarnation(hostId: host, bootId: boot, pid: pid, startTime: start)
    }
    public static func signal(_ identity: ManagedIncarnation) -> Bool {
        guard incarnation(pid: identity.pid) == identity else { return false }
        return ProcessKiller.terminate(pid: identity.pid, expectedStartTime: identity.startTime) == .signalSent
    }
    public static func exitVerified(_ target: ManagedIncarnation) -> Bool {
        if let live = incarnation(pid: target.pid) { return live != target }
        return kill(target.pid, 0) != 0 && errno == ESRCH
    }
    public static func availablePort(in range: ClosedRange<UInt16>, excluding: Set<UInt16> = []) throws -> UInt16 {
        for port in range where !excluding.contains(port) {
            let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw ManagedError.dependencyUnavailable }
            var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd); if result == 0 { return port }
        }
        throw ManagedError.portUnavailable
    }
}

/// Reports never contain recipes or resolved secrets. Missing inputs on recovery
/// require re-enrollment rather than launching with a partial environment.
public actor ManagedSupervisor {
    private let registry: ManagedRegistry
    private let key: Data
    private var processes: [UUID: ManagedTrackedChild] = [:]
    private var forwarders: [UUID: ManagedForwarder] = [:]
    private var launches: [UUID: ManagedLaunch] = [:]
    private let recipes: ManagedRecipes?
    private var nextTailnetCheck: TimeInterval = 0
    private var replacements: [UUID: ManagedTrackedChild] = [:]
    /// Children this helper spawned that no longer belong to a service or move. An exited child stays a
    /// zombie (no identity, no ESRCH) until reaped, so it could never be proven exited; reconcile reaps them.
    private var retiredChildren: [ManagedTrackedChild] = []
    private var scheduledReroutes: Set<UUID> = []
    /// Services whose start() or reroute task is running; those tasks own the relay, so the orphan sweep skips them.
    private var activeOperations: Set<UUID> = [] { didSet { operationEpoch &+= 1 } }
    /// Bumped whenever an operation starts or ends, so a sweep can tell its snapshot went stale across an await.
    private var operationEpoch = 0
    private let treeEvidence = ManagedTreeEvidence()
    private let readinessTimeout: TimeInterval
    /// How long a move watches the new backend through the stable port before draining the old one.
    private let observationWindow: TimeInterval
    public init(registry: ManagedRegistry, key: Data, persistence: ManagedPersistence? = nil, readinessTimeout: TimeInterval = 30,
                observationWindow: TimeInterval = 30) {
        self.registry = registry; self.key = key; self.readinessTimeout = readinessTimeout; self.observationWindow = observationWindow
        recipes = persistence.map { ManagedRecipes(persistence: $0, key: key) }
    }
    private func secret(_ name: String) throws -> String {
        guard let recipes else { throw ManagedError.needsDecision }
        return try recipes.secret(name)
    }
    public func handle(_ request: ManagedRequest, peer: ManagedIncarnation? = nil) async -> ManagedResponse {
        if request.operation == "operation.execute" {
            if let previous = await registry.preflight(request) { return previous }
            if let id = request.payload["operationId"]?.string.flatMap(UUID.init(uuidString:)),
               let operation = await registry.operation(id: id), operation.action == "reroute" {
                return await reroute(request, operation: operation)
            }
        }
        guard ["service.run", "service.adopt", "tailnet.enroll"].contains(request.operation) else { return await registry.handle(request, peer: peer) }
        if let previous = await registry.preflight(request) { return previous }
        if request.operation == "tailnet.enroll" {
            do {
                guard let id = request.payload["serviceId"]?.string.flatMap(UUID.init(uuidString:)),
                      let service = await registry.snapshot().first(where: { $0.id == id }),
                      let stable = service.stablePort, let selector = request.payload["selector"]?.string else { throw ManagedError.invalidInput }
                let data = try await ManagedTailnet.readStatus()
                let route = try ManagedTailnet.inspect(data, selector: selector, stablePort: stable)
                return try await registry.enrollTailnet(request, route: route)
            } catch { return ManagedResponse(requestId: request.requestId, error: error as? ManagedError ?? .dependencyUnavailable) }
        }
        if request.operation == "service.adopt" {
            do {
                guard let raw = request.payload["incarnation"], let port = request.payload["port"]?.integer,
                      (1...65535).contains(port), let name = request.payload["service"]?.string,
                      let cwd = request.payload["cwd"]?.string else { throw ManagedError.invalidInput }
                let target = try JSONDecoder().decode(ManagedIncarnation.self, from: JSONEncoder().encode(raw))
                guard ManagedProcess.incarnation(pid: target.pid) == target else { throw ManagedError.staleIdentity }
                let scan = await PortScanner(pidProvider: { [target.pid] }).scan()
                guard case .success(let entries, _) = scan,
                      entries.contains(where: { $0.pid == target.pid && $0.processStartTime == target.startTime && $0.port == port && $0.state == .listen }) else { throw ManagedError.identityUnavailable }
                let declaration = ManagedLaunch(service: name, executable: "/usr/bin/true", arguments: [], cwd: cwd)
                return try await registry.adopt(request, workspace: declaration.workspace(), name: name,
                                                variant: request.payload["variant"]?.string ?? "default", target: target, port: UInt16(port))
            } catch { return ManagedResponse(requestId: request.requestId, error: error as? ManagedError ?? .invalidInput) }
        }
        do {
            guard let payload = request.payload["launch"] else { throw ManagedError.invalidInput }
            let launch = try JSONDecoder().decode(ManagedLaunch.self, from: JSONEncoder().encode(payload))
            try launch.validate()
            let current = await registry.snapshot()
            let workspace = try launch.workspace()
            let fingerprint = try launch.fingerprint(key: key, secret: secret)
            if let existing = current.first(where: { $0.workspace.filesystemIdentity == workspace.filesystemIdentity && $0.name == launch.service && $0.variant == launch.variant }) {
                // The registry decides whether needs_review is provably finished; otherwise it fails closed.
                if existing.lifecycle == "stopped" || existing.lifecycle == "needs_review" {
                    guard existing.launchFingerprint == fingerprint else { throw ManagedError.incompatibleLaunch }
                    let backend = try ManagedProcess.availablePort(in: 30000...39999, excluding: Set(current.filter { $0.lifecycle != "stopped" }.compactMap(\.backendPort)))
                    try recipes?.save(launch, fingerprint: fingerprint)
                    let restarted = try await registry.restartLaunch(request, serviceId: existing.id, fingerprint: fingerprint, backend: backend)
                    launches[existing.id] = launch
                    launchInBackground(service: restarted, launch: launch)
                    return await registry.handle(request)
                }
                guard existing.launchFingerprint == fingerprint, !launch.configurationFiles.isEmpty,
                      ["running", "release_pending"].contains(existing.lifecycle), let stable = existing.stablePort,
                      let backend = existing.backendPort else { throw ManagedError.incompatibleLaunch }
                guard request.expectedRevision == existing.revision else { throw ManagedError.staleRevision }
                guard existing.fence == nil else { throw ManagedError.operationInProgress }
                let pids = existing.incarnations.map(\.pid)
                let scan = await PortScanner(pidProvider: { pids }).scan()
                guard case .success(let entries, _) = scan,
                      entries.contains(where: { entry in entry.port == backend && entry.state == .listen && entry.localAddress == "127.0.0.1" &&
                          existing.incarnations.contains(where: { $0.pid == entry.pid && $0.startTime == entry.processStartTime }) }) else { throw ManagedError.identityUnavailable }
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 1; config.timeoutIntervalForResource = 1
                let session = URLSession(configuration: config, delegate: NoReadinessRedirect(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (bytes, response) = try await boundedReadiness(session, url: URL(string: "http://127.0.0.1:\(stable)\(launch.readinessPath)")!)
                guard (response as? HTTPURLResponse)?.statusCode == launch.readinessStatus,
                      launch.readinessMarker.map({ String(decoding: bytes, as: UTF8.self).contains($0) }) ?? true,
                      try launch.fingerprint(key: key, secret: secret) == fingerprint else { throw ManagedError.readinessFailed }
                return try await registry.reuseLaunch(request, serviceId: existing.id, fingerprint: fingerprint)
            }
            let backend = try ManagedProcess.availablePort(in: 30000...39999, excluding: Set(current.compactMap(\.backendPort)))
            let stable = try ManagedProcess.availablePort(in: 20000...20999, excluding: Set(current.compactMap(\.stablePort)))
            // Persist reconstructible inputs before the launch intent and spawn.
            try recipes?.save(launch, fingerprint: fingerprint)
            let service = try await registry.beginLaunch(request, workspace: workspace, name: launch.service,
                                                         variant: launch.variant, fingerprint: fingerprint, backend: backend, stable: stable)
            launches[service.id] = launch
            // Long startup returns a durable operation immediately. Connection loss
            // does not cancel this task or release the claim.
            launchInBackground(service: service, launch: launch)
            return await registry.handle(request)
        } catch {
            // Another connection may have committed this request while an async
            // probe was running. Return its durable result, never launch twice.
            if let previous = await registry.preflight(request) { return previous }
            return ManagedResponse(requestId: request.requestId, error: error as? ManagedError ?? .invalidInput)
        }
    }
    public func recoverRoutes() async {
        let services = await registry.snapshot()
        let targets = services.filter { $0.fence == nil && $0.routeGeneration > 0 && $0.lifecycle != "stopped" }
        guard !targets.isEmpty else { return }
        let pids = Array(Set(targets.flatMap { $0.incarnations.map(\.pid) }))
        let scan = await PortScanner(pidProvider: { pids }).scan()
        guard case .success(let entries, _) = scan else { return }
        for service in services where service.fence == nil && service.routeGeneration > 0 && service.lifecycle != "stopped" {
            guard let stable = service.stablePort, let backend = service.backendPort,
                  !service.incarnations.isEmpty,
                  service.incarnations.allSatisfy({ ManagedProcess.incarnation(pid: $0.pid) == $0 }),
                  Self.ownsBackend(service, entries: entries) else { continue }
            // Retain the published allocation; a collision never chooses a new URL.
            do {
                let forwarder = try ManagedForwarder(stablePort: stable, backendPort: backend)
                forwarder.switchBackend(to: backend, generation: service.routeGeneration)
                forwarders[service.id] = forwarder
            } catch { continue }
            if let launch = try? recipes?.load(fingerprint: service.launchFingerprint),
               (try? launch.fingerprint(key: key, secret: secret)) == service.launchFingerprint {
                launches[service.id] = launch
            }
            // Recovering a recipe does not prove complete process ancestry.
        }
    }
    private func retire(_ child: ManagedTrackedChild?) {
        guard let child, !child.isReaped else { return }
        retiredChildren.append(child)
    }
    public func reconcile() async {
        for child in Array(processes.values) + Array(replacements.values) + retiredChildren { _ = child.treeVerified() }
        retiredChildren.removeAll { $0.isReaped }
        let services = await registry.snapshot()
        let pids = LibProc.listAllPids()
        for service in services where ["running", "release_pending"].contains(service.lifecycle) && service.fence == nil {
            let descendants = ManagedAncestry.discover(known: service.incarnations, pids: pids)
            try? await registry.recordDescendants(serviceId: service.id, expectedRevision: service.revision, descendants: descendants)
        }
        let evidence = treeEvidence
        try? await registry.reconcileStops(treeVerified: { evidence.verified($0) })
        try? await registry.cleanup(treeVerified: { evidence.verified($0) }, signal: ManagedProcess.signal)
        await dropOrphanedForwarders()
        if ProcessInfo.processInfo.systemUptime >= nextTailnetCheck, services.contains(where: { $0.tailnet != nil }) {
            nextTailnetCheck = ProcessInfo.processInfo.systemUptime + 60
            let data = try? await ManagedTailnet.readStatus()
            for service in services {
                guard let route = service.tailnet else { continue }
                let observed = data.flatMap { try? ManagedTailnet.inspect($0, selector: route.selector, stablePort: route.stablePort) }
                try? await registry.observeTailnet(serviceId: service.id, expectedFingerprint: route.fingerprint, observed: observed)
            }
        }
    }
    /// True when a live recorded incarnation of the service is LISTENing on its backend port at 127.0.0.1.
    private static func ownsBackend(_ service: ManagedService, entries: [PortEntry]) -> Bool {
        guard let backend = service.backendPort else { return false }
        return owns(port: backend, targets: service.incarnations, entries: entries)
    }
    /// True when one of `targets`, still the same live process, is LISTENing on `port` at 127.0.0.1.
    private static func owns(port: UInt16, targets: [ManagedIncarnation], entries: [PortEntry]) -> Bool {
        entries.contains { entry in
            entry.port == port && entry.state == .listen && entry.localAddress == "127.0.0.1" &&
            targets.contains { $0.pid == entry.pid && $0.startTime == entry.processStartTime && ManagedProcess.incarnation(pid: $0.pid) == $0 }
        }
    }
    /// Scans only `targets`; a failed scan is never ownership.
    private static func owns(port: UInt16, targets: [ManagedIncarnation]) async -> Bool {
        let pids = targets.map(\.pid)
        guard case .success(let entries, _) = await PortScanner(pidProvider: { pids }).scan() else { return false }
        return owns(port: port, targets: targets, entries: entries)
    }
    /// A relay must never forward to a port nobody owns: once the listener is gone, an unrelated process
    /// could bind it and the stable URL (and any Tailscale Serve route on it) would serve that process.
    /// Relays of gone or stopped services are stopped. Every other relay is open only while a live recorded
    /// incarnation listens on the backend port; otherwise it stays bound (so the stable port stays reserved)
    /// but closes connections. A live launcher or other recorded process is not ownership. Services with a
    /// running start() or reroute task are skipped, and that is re-checked after each await.
    private func dropOrphanedForwarders() async {
        let candidates = Set(forwarders.keys).subtracting(activeOperations)
        guard !candidates.isEmpty else { return }
        let epoch = operationEpoch
        let services = await registry.snapshot()
        let relayed = services.filter { candidates.contains($0.id) && $0.lifecycle != "stopped" }
        let pids = Array(Set(relayed.flatMap { $0.incarnations.map(\.pid) }))
        var entries: [PortEntry]?
        if !relayed.isEmpty, case .success(let scanned, _) = await PortScanner(pidProvider: { pids }).scan() { entries = scanned }
        // No awaits below. If any start/reroute began or ended meanwhile the snapshot may be stale; skip this sweep.
        guard epoch == operationEpoch else { return }
        for id in candidates where !activeOperations.contains(id) {
            guard let forwarder = forwarders[id] else { continue }
            guard let service = services.first(where: { $0.id == id }), service.lifecycle != "stopped" else {
                forwarders.removeValue(forKey: id)?.stop()
                continue
            }
            forwarder.setBackendVerified(entries.map { Self.ownsBackend(service, entries: $0) } ?? false)
        }
    }
    private func boundedReadiness(_ session: URLSession, url: URL) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(from: url)
        var data = Data()
        for try await byte in stream {
            guard data.count < 65_536 else { throw ManagedError.readinessFailed }
            data.append(byte)
        }
        return (data, response)
    }
    private func reroute(_ request: ManagedRequest, operation: ManagedOperation) async -> ManagedResponse {
        do {
            guard let service = await registry.snapshot().first(where: { $0.id == operation.serviceId }),
                  let launch = launches[service.id], launch.parallelSafe,
                  !launch.configurationFiles.isEmpty,
                  try launch.fingerprint(key: key, secret: secret) == service.launchFingerprint,
                  let forwarder = forwarders[service.id] else { throw ManagedError.incompatibleLaunch }
            let services = await registry.snapshot()
            let occupied = Set(services.compactMap(\.backendPort) + services.compactMap { $0.transition?.newBackend })
            let port = try ManagedProcess.availablePort(in: 30000...39999, excluding: occupied)
            let response = try await registry.beginReroute(request, backend: port)
            guard response.error == nil else { return response }
            guard scheduledReroutes.insert(operation.id).inserted else { return response }
            activeOperations.insert(service.id)
            Task { await self.prepareReplacement(service: service, operationId: operation.id, launch: launch, port: port, forwarder: forwarder) }
            return response
        } catch { return ManagedResponse(requestId: request.requestId, error: error as? ManagedError ?? .dependencyUnavailable) }
    }
    private func healthy(_ launch: ManagedLaunch, port: UInt16, session: URLSession) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(launch.readinessPath)"),
              let (bytes, response) = try? await boundedReadiness(session, url: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == launch.readinessStatus &&
            (launch.readinessMarker.map { String(decoding: bytes, as: UTF8.self).contains($0) } ?? true)
    }
    private func prepareReplacement(service: ManagedService, operationId: UUID, launch: ManagedLaunch, port: UInt16, forwarder: ManagedForwarder) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1; configuration.timeoutIntervalForResource = 1
        defer { activeOperations.remove(service.id) }
        let session = URLSession(configuration: configuration, delegate: NoReadinessRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var switched = false
        var replacementTargets: [ManagedIncarnation] = []
        do {
            guard try launch.fingerprint(key: key, secret: secret) == service.launchFingerprint,
                  let stable = service.stablePort, service.backendPort != nil else { throw ManagedError.incompatibleLaunch }
            let process = try ManagedTrackedChild(launch: launch, port: port, environment: launch.resolvedEnvironment(port: port, secret: secret))
            replacements[operationId] = process
            let root = process.identity
            var targets = [root]
            replacementTargets = targets
            try await registry.recordReplacement(serviceId: service.id, operationId: operationId, targets: targets)
            try process.resume()
            let deadline = ProcessInfo.processInfo.systemUptime + readinessTimeout
            var successes = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard ManagedProcess.incarnation(pid: root.pid) == root else { throw ManagedError.staleIdentity }
                targets += ManagedAncestry.discover(known: targets)
                replacementTargets = targets
                try await registry.recordReplacement(serviceId: service.id, operationId: operationId, targets: targets)
                let owned = await Self.owns(port: port, targets: targets)
                let ready = owned ? await healthy(launch, port: port, session: session) : false
                if ready { successes += 1 } else { successes = 0 }
                if successes == 3 { break }
                try await Task.sleep(for: .seconds(1))
            }
            guard successes == 3, try launch.fingerprint(key: key, secret: secret) == service.launchFingerprint else { throw ManagedError.readinessFailed }
            try await registry.switchReroute(serviceId: service.id, operationId: operationId) { port, generation in
                forwarder.switchBackend(to: port, generation: generation)
                // The replacement's listener was proven owned by scan before this switch.
                forwarder.setBackendVerified(true)
            }
            switched = true
            let observationDeadline = ProcessInfo.processInfo.systemUptime + observationWindow
            // The orphan sweep skips a running move, so this task alone keeps proving the relay's target.
            // A replacement that dies, or stops owning its port (which an unrelated process could then
            // bind), rolls back instead of receiving traffic.
            while ProcessInfo.processInfo.systemUptime < observationDeadline {
                guard targets.allSatisfy({ ManagedProcess.incarnation(pid: $0.pid) == $0 }),
                      await Self.owns(port: port, targets: targets),
                      await healthy(launch, port: stable, session: session) else { throw ManagedError.readinessFailed }
                try await Task.sleep(for: .seconds(1))
            }
            let drainDeadline = ProcessInfo.processInfo.systemUptime + 60
            while forwarder.connectionCount(generation: service.routeGeneration) > 0 && ProcessInfo.processInfo.systemUptime < drainDeadline {
                guard targets.allSatisfy({ ManagedProcess.incarnation(pid: $0.pid) == $0 }),
                      await Self.owns(port: port, targets: targets) else { throw ManagedError.readinessFailed }
                try await Task.sleep(for: .seconds(1))
            }
            if forwarder.connectionCount(generation: service.routeGeneration) == 0,
               service.treeComplete, let oldChild = processes[service.id], oldChild.treeVerified() {
                do {
                    try await registry.retireOldRoute(serviceId: service.id, operationId: operationId, treeVerified: { oldChild.treeVerified() })
                    let exitDeadline = ProcessInfo.processInfo.systemUptime + 2
                    while ProcessInfo.processInfo.systemUptime < exitDeadline {
                        _ = oldChild.treeVerified()
                        if ManagedProcess.exitVerified(oldChild.identity) { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard oldChild.treeVerified(), ManagedProcess.exitVerified(oldChild.identity) else { throw ManagedError.needsDecision }
                    treeEvidence.record(process, service: service.id)
                    retire(processes.updateValue(process, forKey: service.id))
                    try await registry.completeReroute(serviceId: service.id, operationId: operationId,
                                                       oldTreeVerified: oldChild.treeVerified(), newTreeVerified: process.treeVerified())
                    replacements.removeValue(forKey: operationId)
                    return
                } catch {
                    try await registry.finishReroute(serviceId: service.id, operationId: operationId, outcome: "old_tree_exit_unverified")
                    return
                }
            }
            // Sampling descendants does not authorize automatic old-tree killing.
            // Preserve the backend and every remaining stream for a user decision.
            let outcome = forwarder.connectionCount(generation: service.routeGeneration) > 0 ? "drain_timeout_old_backend_retained" : "route_verified_old_tree_retained_for_review"
            try await registry.finishReroute(serviceId: service.id, operationId: operationId, outcome: outcome)
        } catch {
            var replacementStopped = false
            var replacementSpawned = false
            if !switched, let replacement = replacements[operationId] {
                // Only the replacement's own processes; the old backend keeps serving.
                replacementSpawned = true
                replacementStopped = await terminateStarted(replacementTargets, child: replacement)
            } else {
                replacements[operationId]?.discardUnstarted()
            }
            // Keep reaping the child until it has exited; dropping it unreaped would leave a zombie.
            retire(replacements.removeValue(forKey: operationId))
            // After the switch the relay points at a backend that just failed; close it until proven otherwise.
            if switched { forwarder.setBackendVerified(false) }
            if switched, let old = service.backendPort, await healthy(launch, port: old, session: session) {
                do {
                    try await registry.rollbackReroute(serviceId: service.id, operationId: operationId) { port, generation in
                        forwarder.switchBackend(to: port, generation: generation)
                    }
                    forwarder.setBackendVerified(await Self.owns(port: old, targets: service.incarnations))
                } catch {
                    try? await registry.finishReroute(serviceId: service.id, operationId: operationId, outcome: "no_healthy_backend")
                }
            } else if !switched {
                // A forked replacement never verifies its tree, so let the registry decide from the
                // recorded targets whether every one is proven exited. A target we know of but cannot
                // prove exited blocks the abandon even when the registry never recorded it.
                let outcome = replacementStopped ? "preparation_failed_replacement_stopped"
                    : replacementSpawned ? "preparation_failed_replacement_tree_unverified"
                    : "preparation_failed_before_replacement_started"
                do {
                    guard replacementTargets.allSatisfy(ManagedProcess.exitVerified) else { throw ManagedError.needsDecision }
                    try await registry.abandonReplacement(serviceId: service.id, operationId: operationId, outcome: outcome)
                } catch {
                    try? await registry.finishReroute(serviceId: service.id, operationId: operationId, outcome: "preparation_failed_replacement_exit_unverified")
                }
            } else {
                try? await registry.finishReroute(serviceId: service.id, operationId: operationId, outcome: "no_healthy_backend")
            }
        }
    }
    /// Marks the service as owning its relay before the task runs, so no sweep can interleave.
    private func launchInBackground(service: ManagedService, launch: ManagedLaunch) {
        activeOperations.insert(service.id)
        Task { await self.start(service: service, launch: launch) }
    }
    private func start(service: ManagedService, launch: ManagedLaunch) async {
        defer { activeOperations.remove(service.id) }
        do {
            guard let backend = service.backendPort, let stable = service.stablePort else { throw ManagedError.invalidInput }
            guard try launch.fingerprint(key: key, secret: secret) == service.launchFingerprint else { throw ManagedError.incompatibleLaunch }
            let process = try ManagedTrackedChild(launch: launch, port: backend, environment: launch.resolvedEnvironment(port: backend, secret: secret))
            retire(processes.updateValue(process, forKey: service.id))
            let identity = process.identity
            try await registry.recordChild(serviceId: service.id, incarnation: identity)
            treeEvidence.record(process, service: service.id)
            try process.resume()
            let forwarder = try forwarders[service.id] ?? ManagedForwarder(stablePort: stable, backendPort: backend)
            forwarder.switchBackend(to: backend, generation: service.routeGeneration + 1)
            // Gate the relay until a scan proves this child owns `backend`: until then another process may hold
            // that port (grabbed between availablePort() and the child's bind). A reused relay that an earlier
            // sweep or run left open is closed here too. The readiness loop opens it per scan; the sweep
            // re-verifies it after start ends.
            forwarder.setBackendVerified(false)
            forwarders[service.id] = forwarder
            let deadline = ProcessInfo.processInfo.systemUptime + readinessTimeout
            var successes = 0
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 1; configuration.timeoutIntervalForResource = 1
            let session = URLSession(configuration: configuration, delegate: NoReadinessRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard ManagedProcess.incarnation(pid: identity.pid) == identity else { throw ManagedError.staleIdentity }
                guard let current = await registry.snapshot().first(where: { $0.id == service.id }) else { throw ManagedError.staleRevision }
                let descendants = ManagedAncestry.discover(known: current.incarnations)
                try await registry.recordDescendants(serviceId: service.id, expectedRevision: current.revision, descendants: descendants)
                let known = current.incarnations + descendants
                let scan = await PortScanner(pidProvider: { known.map(\.pid) }).scan()
                let owns: Bool
                if case .success(let entries, _) = scan {
                    owns = entries.contains { entry in
                        entry.port == backend && entry.state == .listen && entry.localAddress == "127.0.0.1" &&
                        known.contains { $0.pid == entry.pid && $0.startTime == entry.processStartTime && ManagedProcess.incarnation(pid: $0.pid) == $0 }
                    }
                } else { owns = false }
                forwarder.setBackendVerified(owns)
                let url = URL(string: "http://127.0.0.1:\(stable)\(launch.readinessPath)")!
                if owns, let (bytes, response) = try? await boundedReadiness(session, url: url),
                   (response as? HTTPURLResponse)?.statusCode == launch.readinessStatus,
                   launch.readinessMarker.map({ String(decoding: bytes, as: UTF8.self).contains($0) }) ?? true {
                    successes += 1
                    if successes == 3 {
                        try await registry.finishLaunch(serviceId: service.id, ready: true, treeComplete: process.treeVerified())
                        return
                    }
                } else { successes = 0 }
                try await Task.sleep(for: .seconds(1))
            }
            throw ManagedError.readinessFailed
        } catch {
            forwarders.removeValue(forKey: service.id)?.stop()
            var treeComplete = false
            if let child = processes[service.id] {
                let recorded = await registry.snapshot().first(where: { $0.id == service.id })?.incarnations ?? []
                treeComplete = await terminateStarted(recorded + [child.identity], child: child)
            }
            try? await registry.finishLaunch(serviceId: service.id, ready: false, treeComplete: treeComplete)
        }
    }
    /// Terminates what a failed launch started. Every signal is identity-checked
    /// (PID + start time); SIGTERM first, bounded grace, then SIGKILL. Returns true
    /// only when every target is proven exited and the kernel watch saw no untracked fork.
    private func terminateStarted(_ initial: [ManagedIncarnation], child: ManagedTrackedChild) async -> Bool {
        child.discardUnstarted()
        var seen: [ManagedIncarnation] = []
        for target in initial + ManagedAncestry.discover(known: initial) where !seen.contains(target) { seen.append(target) }
        let targets = seen
        for target in targets { _ = ManagedProcess.signal(target) }
        await Self.waitForExit(targets, child: child, seconds: 2)
        for target in targets where ManagedProcess.incarnation(pid: target.pid) == target {
            _ = ProcessKiller.forceKill(pid: target.pid, expectedStartTime: target.startTime)
        }
        await Self.waitForExit(targets, child: child, seconds: 2)
        let treeKnown = child.treeVerified() // also reaps the direct child once it exits
        return treeKnown && targets.allSatisfy(ManagedProcess.exitVerified)
    }
    private static func waitForExit(_ targets: [ManagedIncarnation], child: ManagedTrackedChild, seconds: TimeInterval) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            _ = child.treeVerified()
            if targets.allSatisfy(ManagedProcess.exitVerified) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class NoReadinessRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
