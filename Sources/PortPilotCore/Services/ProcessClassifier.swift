import Foundation

public enum PortCategory: String, CaseIterable, Codable, Sendable {
    case devServers, databases, infrastructure, editorServices, apps, system, unknown

    public var displayName: String {
        switch self {
        case .devServers: "Dev Servers"
        case .databases: "Databases"
        case .infrastructure: "Proxies & Infrastructure"
        case .editorServices: "Editor Services"
        case .apps: "macOS Apps"
        case .system: "System"
        case .unknown: "Unknown"
        }
    }

    public static func categorize(_ entry: PortEntry) -> PortCategory {
        ProcessClassifier.classify(entry).category
    }

    public static func isInfrastructure(_ entry: PortEntry) -> Bool {
        categorize(entry) == .infrastructure
    }

    static func isMacApp(_ entry: PortEntry) -> Bool {
        let category = categorize(entry)
        return category == .apps || category == .editorServices
    }
}

public enum ProcessOwnership: String, Sendable {
    case project, app, shared, system, unresolved
}

public struct ProcessClassification: Equatable, Sendable {
    public let category: PortCategory
    public let ownership: ProcessOwnership
    public let reason: String
    public let isOverride: Bool

    public var resolvesProject: Bool {
        ownership == .project || ownership == .unresolved
    }
}

/// Deterministic labels, not a trust or termination policy. Port numbers never
/// establish identity. Rules can describe a binary, but cannot authorize signals.
public enum ProcessClassifier {
    public static let catalogVersion = 1
    private static let runtimes: Set<String> = [
        "node", "python", "python3", "Python", "ruby", "java", "go", "bun", "deno",
        "cargo", "mix", "beam.smp", "next-server", "vite", "webpack", "esbuild", "tsx",
        "uvicorn", "gunicorn", "flask", "rails", "puma", "php",
    ]
    private static let databases: Set<String> = [
        "postgres", "mysqld", "mariadbd", "redis-server", "mongod", "cockroach", "arangod",
    ]
    private static let infrastructure: Set<String> = [
        "cloudflared", "cliproxyapi", "caddy", "nginx", "haproxy", "traefik",
        "dockerd", "com.docker.backend", "tailscaled", "portless",
    ]

    static func isRuntimeExecutable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return runtimes.contains(name) || name.hasPrefix("python3.")
    }

    public static func classify(_ entry: PortEntry, override: PortCategory? = nil) -> ProcessClassification {
        func result(_ category: PortCategory, _ owner: ProcessOwnership, _ reason: String,
                    overridden: Bool = false) -> ProcessClassification {
            ProcessClassification(category: category, ownership: owner, reason: reason, isOverride: overridden)
        }
        if let override {
            let owner: ProcessOwnership
            switch override {
            case .infrastructure: owner = .shared
            case .apps, .editorServices: owner = .app
            case .system: owner = .system
            default: owner = entry.projectPath == nil ? .unresolved : .project
            }
            return result(override, owner, "Your saved category for this executable and context", overridden: true)
        }
        let path = entry.executablePath
        let executable = (path as NSString).lastPathComponent
        guard !path.isEmpty else { return result(.unknown, .unresolved, "Executable identity unavailable") }

        // An interpreted service needs script evidence; node + a familiar port
        // is insufficient. Do not classify every process in the project as shared.
        if isRuntimeExecutable(path), let script = entry.scriptPath,
           script.contains("/node_modules/portless/") {
            return result(.infrastructure, .shared, "Portless runtime script")
        }
        if path.contains("/Tailscale.app/"), executable == "IPNExtension" {
            return result(.infrastructure, .app, "Tailscale app networking extension")
        }
        if infrastructure.contains(executable) {
            return result(.infrastructure, .shared, "Known infrastructure executable: \(executable)")
        }
        // Framework Python embeds a .app; it remains a runtime.
        let frameworkRuntime = path.contains(".framework/") && isRuntimeExecutable(path)
        let isBundle = path.contains(".app/") && !frameworkRuntime
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") {
            return result(.system, .system, "Operating-system executable location")
        }
        if VSCodeExtensions.extractExtensionID(from: entry.scriptPath ?? path) != nil ||
            (isBundle && (path.contains("/Visual Studio Code.app/") || path.contains("/Cursor.app/"))) {
            return result(.editorServices, .app, "Editor-owned executable or extension script")
        }
        if isBundle { return result(.apps, .app, "Executable inside an application bundle") }
        if databases.contains(executable) {
            return result(.databases, entry.projectPath == nil ? .unresolved : .project,
                          "Known database executable: \(executable)")
        }
        if entry.projectPath != nil {
            return result(.devServers, .project, "Working directory resolves to a project")
        }
        if isRuntimeExecutable(path) {
            return result(.devServers, .unresolved, "Development runtime: \(executable); owner unresolved")
        }
        return result(.unknown, .unresolved, "No matching process rule; port number is only a hint")
    }

    /// Exact executable plus context. Generic runtimes must not share one global
    /// override across all projects. No PID, port, or transient start time in keys.
    public static func overrideKey(for entry: PortEntry) -> String? {
        guard !entry.executablePath.isEmpty else { return nil }
        if isRuntimeExecutable(entry.executablePath), entry.scriptPath == nil, entry.projectPath == nil {
            return nil
        }
        let components = [entry.executablePath, entry.scriptPath ?? "",
                          isRuntimeExecutable(entry.executablePath) ? entry.projectPath ?? "" : ""]
        guard let data = try? JSONEncoder().encode(components) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func serviceKey(for entry: PortEntry) -> String {
        // Root-scoped by the caller. Preserve executable/script identities so a
        // different service reusing an expected port still warrants review.
        let components = [entry.executablePath, entry.scriptPath ?? "", String(entry.port), entry.protocol.rawValue]
        return String(decoding: try! JSONEncoder().encode(components), as: UTF8.self)
    }
}
