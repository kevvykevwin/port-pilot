import Foundation
import Darwin
import PortPilotCore

// Explicit foreground operation only. Building never enrolls or installs a job.
do {
    if Array(CommandLine.arguments.dropFirst()) == ["--version"] {
        print(try ManagedVersion.read()); exit(0)
    }
    if Array(CommandLine.arguments.dropFirst()) == ["--capabilities"] {
        // Read by scripts/managed-helper.py before it quiesces the running helper.
        print(try ManagedExportCapabilities.json())
        exit(0)
    }
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print("PortPilotHelper --capabilities   (print supported protocol/storage schemas as JSON)")
        print("PortPilotHelper [--state-dir PATH] enroll ACTOR read|owner|coordinator|user")
        print("PortPilotHelper [--state-dir PATH] serve")
        print("PortPilotHelper [--state-dir PATH] enroll-secret NAME PRIVATE-FILE")
        print("Enrollment is explicit and offline. No launch agent is installed by this command.")
        exit(0)
    }
    var root = ManagedPersistence.defaultRoot
    if let i = arguments.firstIndex(of: "--state-dir"), i + 1 < arguments.count {
        root = URL(fileURLWithPath: arguments[i + 1]); arguments.removeSubrange(i...i + 1)
    }
    let persistence = try ManagedPersistence(root: root)
    let lifecycle = arguments.first?.hasPrefix("enroll") == true ? try ManagedLifecycleLock(root: root) : nil
    defer { withExtendedLifetime(lifecycle) {} }
    if arguments.first == "enroll-secret" {
        guard arguments.count == 3 else { throw ManagedError.invalidInput }
        try ManagedRecipes(persistence: persistence, key: Data()).enrollSecret(arguments[1], from: URL(fileURLWithPath: arguments[2]))
        print("Secret reference enrolled.")
    } else if arguments.first == "enroll" {
        guard arguments.count == 3, let scope = ManagedActor.Scope(rawValue: arguments[2]),
              !arguments[1].isEmpty, arguments[1].utf8.count <= 256 else { throw ManagedError.invalidInput }
        var actors = try persistence.read("actors.json").map { try JSONDecoder().decode([ManagedActor].self, from: $0) } ?? []
        guard !actors.contains(where: { $0.id == arguments[1] }) else { throw ManagedError.invalidInput }
        let token = UUID().uuidString + UUID().uuidString
        actors.append(ManagedActor(id: arguments[1], scope: scope, credentialHash: ManagedDigest.hash(Data(token.utf8))))
        try persistence.write("actors.json", data: JSONEncoder().encode(actors))
        // Credentials are delivered to a private file, never stdout/logs.
        let file = "credential-\(UUID().uuidString).json"
        let credential: [String: String] = ["actor": arguments[1], "credential": token]
        try persistence.write(file, data: JSONEncoder().encode(credential))
        if scope == .user {
            try persistence.write("gui-credential.json", data: JSONEncoder().encode(credential))
        }
        print(root.appendingPathComponent(file).path)
    } else {
        guard arguments.isEmpty || arguments == ["serve"] else { throw ManagedError.invalidInput }
        guard let actorData = try persistence.read("actors.json") else { throw ManagedError.unauthorized }
        let actors = try JSONDecoder().decode([ManagedActor].self, from: actorData)
        let key: Data
        if let saved = try persistence.read("fingerprint.key") { key = saved }
        else {
            key = Data((UUID().uuidString + UUID().uuidString).utf8)
            try persistence.write("fingerprint.key", data: key)
        }
        let registry = ManagedRegistry(persistence: persistence, actors: actors)
        let supervisor = ManagedSupervisor(registry: registry, key: key, persistence: persistence)
        let server = try ManagedSocketServer(path: root.appendingPathComponent("control.sock").path) { request, peer in
            await supervisor.handle(request, peer: peer)
        }
        Task.detached {
            await supervisor.recoverRoutes()
            while !Task.isCancelled {
                await supervisor.reconcile()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        try server.run()
    }
} catch {
    let code = (error as? ManagedError)?.rawValue ?? "recovery_required"
    FileHandle.standardError.write(Data("PortPilotHelper: \(code)\n".utf8))
    exit(1)
}
