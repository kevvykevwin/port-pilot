import Foundation
import Darwin
import PortPilotCore

do {
    if Array(CommandLine.arguments.dropFirst()) == ["--version"] {
        print(try ManagedVersion.read()); exit(0)
    }
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] {
        print("""
        portpilot <status|services|inspect|run|claim|release|keep|propose|operation|operations|events> [options]
          --state-dir PATH       Helper state root (default Application Support/PortPilot/Managed)
          --credential-file PATH Private enrolled actor credential
          --revision N           Required service revision for mutations
          --json                 Structured output (also the default)
        run: --service NAME [--variant NAME] [--readiness-path /health] (--port-arg=--port | --port-env PORT) -- /absolute/executable args
          [--env NAME=VALUE] [--secret NAME=REFERENCE] [--config PATH] [--parallel-safe true|false]
        adopt: --service NAME --pid PID --port PORT (user credential required; no restart recipe)
        inspect/claim/release/keep/propose: SERVICE-UUID
        release: --claim-id UUID; keep: --value true|false; propose: --action stop|reroute|force
        operation: OPERATION-UUID
        acknowledge/decide/execute: OPERATION-UUID --service-id UUID --revision N
        decide additionally requires --approve true|false from an enrolled user credential.
        tailnet-enroll: SERVICE-UUID --selector host.tailnet.ts.net:443 --revision N (adopts an existing route; no configuration writes)
        quiesce: defer writes for lifecycle work (refuses active children); resume: --checkpoint ID
        Long operations return accepted + operationId; inspect the operation for the observed outcome.
        """)
        exit(0)
    }
    func option(_ name: String) throws -> String? {
        if let i = args.firstIndex(where: { $0.hasPrefix(name + "=") }) {
            return String(args.remove(at: i).dropFirst(name.count + 1))
        }
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { throw ManagedError.invalidInput }
        let value = args[i + 1]; args.removeSubrange(i...i + 1); return value
    }
    // Split command argv first: helper flags must never rewrite child arguments.
    var child: [String] = []
    if let separator = args.firstIndex(of: "--") { child = Array(args.dropFirst(separator + 1)); args = Array(args.prefix(separator)) }
    let root = try option("--state-dir").map { URL(fileURLWithPath: $0) } ?? ManagedPersistence.defaultRoot
    guard let credentialPath = try option("--credential-file") else { throw ManagedError.unauthorized }
    var info = stat()
    guard lstat(credentialPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ManagedError.unauthorized }
    let credential = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: credentialPath)))
    guard let actor = credential["actor"], let token = credential["credential"] else { throw ManagedError.unauthorized }
    let revisionText = try option("--revision")
    let revision = revisionText.flatMap(Int.init)
    if revisionText != nil && revision == nil { throw ManagedError.invalidInput }
    let requestId = try option("--request-id") ?? UUID().uuidString
    args.removeAll { $0 == "--json" }
    let command = args.removeFirst()
    var payload: [String: ManagedJSON] = [:]
    let operation: String
    switch command {
    case "status": operation = "status"
    case "services": operation = "services.list"
    case "events": operation = "events.list"
    case "operations": operation = "operations.list"
    case "quiesce": operation = "lifecycle.quiesce"
    case "resume":
        operation = "lifecycle.resume"
        guard let checkpoint = try option("--checkpoint") else { throw ManagedError.invalidInput }
        payload["checkpoint"] = .string(checkpoint)
    case "tailnet-enroll":
        operation = "tailnet.enroll"
        guard let selector = try option("--selector"), args.count == 1 else { throw ManagedError.invalidInput }
        payload = ["serviceId": .string(args.removeFirst()), "selector": .string(selector)]
    case "run":
        operation = "service.run"
        guard let service = try option("--service"), let executable = child.first else { throw ManagedError.invalidInput }
        let portArgument = try option("--port-arg")
        let portEnvironment = try option("--port-env")
        guard (portArgument == nil) != (portEnvironment == nil), portArgument == nil || portArgument!.hasPrefix("-") else { throw ManagedError.invalidInput }
        let variant = try option("--variant") ?? "default"
        let readiness = try option("--readiness-path") ?? "/"
        var configurations: [String] = []
        while let path = try option("--config") { configurations.append(URL(fileURLWithPath: path).standardizedFileURL.path) }
        func bindings(_ flag: String) throws -> [String: String] {
            var result: [String: String] = [:]
            while let value = try option(flag) {
                guard let separator = value.firstIndex(of: "=") else { throw ManagedError.invalidInput }
                let name = String(value[..<separator])
                guard result[name] == nil else { throw ManagedError.invalidInput }
                result[name] = String(value[value.index(after: separator)...])
            }
            return result
        }
        let environment = try bindings("--env"), secrets = try bindings("--secret")
        let parallel = try option("--parallel-safe") ?? "false"
        guard ["true", "false"].contains(parallel) else { throw ManagedError.invalidInput }
        let launch = ManagedLaunch(service: service, variant: variant, executable: executable,
                                   arguments: Array(child.dropFirst()) + (portArgument.map { [$0, "{port}"] } ?? []),
                                   cwd: FileManager.default.currentDirectoryPath, readinessPath: readiness, configurationFiles: configurations,
                                   parallelSafe: parallel == "true", portEnvironment: portEnvironment, environment: environment, secretReferences: secrets)
        try launch.validate(); payload["launch"] = try .value(launch)
    case "adopt":
        operation = "service.adopt"
        guard let service = try option("--service"), let pidText = try option("--pid"), let pid = Int32(pidText), pid > 0,
              let portText = try option("--port"), let port = Int(portText), (1...65535).contains(port),
              let identity = ManagedProcess.incarnation(pid: pid) else { throw ManagedError.invalidInput }
        payload = ["service": .string(service), "variant": .string(try option("--variant") ?? "default"),
                   "cwd": .string(FileManager.default.currentDirectoryPath), "port": .integer(port), "incarnation": try .value(identity)]
    case "inspect", "claim", "release", "keep", "propose":
        let mapping = ["inspect": "service.inspect", "claim": "claim.acquire", "release": "claim.release", "keep": "service.keep", "propose": "operation.propose"]
        operation = mapping[command]!
        if command == "release" { guard let id = try option("--claim-id") else { throw ManagedError.invalidInput }; payload["claimId"] = .string(id) }
        if command == "keep" { guard let value = try option("--value"), ["true", "false"].contains(value) else { throw ManagedError.invalidInput }; payload["keep"] = .bool(value == "true") }
        if command == "propose" { guard let action = try option("--action") else { throw ManagedError.invalidInput }; payload["action"] = .string(action) }
        guard args.count == 1 else { throw ManagedError.invalidInput }; payload["serviceId"] = .string(args.removeFirst())
    case "acknowledge", "decide", "execute":
        operation = command == "acknowledge" ? "operation.acknowledge" : command == "decide" ? "decision.resolve" : "operation.execute"
        guard let service = try option("--service-id") else { throw ManagedError.invalidInput }
        payload["serviceId"] = .string(service)
        if command == "decide" {
            guard let approved = try option("--approve"), ["true", "false"].contains(approved) else { throw ManagedError.invalidInput }
            payload["approved"] = .bool(approved == "true")
        }
        guard args.count == 1 else { throw ManagedError.invalidInput }; payload["operationId"] = .string(args.removeFirst())
    case "operation":
        operation = "operation.inspect"
        guard args.count == 1 else { throw ManagedError.invalidInput }; payload["operationId"] = .string(args.removeFirst())
    default: throw ManagedError.invalidInput
    }
    if ["services", "events", "operations"].contains(command) {
        if let value = try option("--limit") { guard let limit = Int(value) else { throw ManagedError.invalidInput }; payload["limit"] = .integer(limit) }
        if let cursor = try option("--cursor") { payload["cursor"] = .string(cursor) }
    }
    guard args.isEmpty else { throw ManagedError.invalidInput }
    let request = ManagedRequest(requestId: requestId, operation: operation, actor: actor, credential: token,
                                 expectedRevision: ["run", "adopt"].contains(command) ? (revision ?? 0) : revision, payload: payload)
    let response = try ManagedSocket.request(request, path: root.appendingPathComponent("control.sock").path)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(response)); print("")
    switch response.error {
    case nil: exit(0)
    case .invalidInput, .protocolMismatch: exit(2)
    case .dependencyUnavailable, .busy: exit(3)
    case .staleRevision, .staleIdentity, .incompatibleLaunch, .operationInProgress: exit(4)
    case .needsDecision: exit(5)
    default: exit(1)
    }
} catch {
    let error = error as? ManagedError ?? .invalidInput
    let response = ManagedResponse(requestId: nil, error: error)
    if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data); print("") }
    exit(error == .dependencyUnavailable ? 3 : 2)
}
