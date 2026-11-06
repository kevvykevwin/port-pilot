import Foundation
import CryptoKit

public enum ManagedError: String, Error, Codable, Sendable {
    case invalidInput = "invalid_input", unauthorized, protocolMismatch = "protocol_mismatch"
    case staleRevision = "stale_revision", staleIdentity = "stale_identity"
    case identityUnavailable = "identity_unavailable", incompatibleLaunch = "incompatible_launch"
    case portUnavailable = "port_unavailable", readinessFailed = "readiness_failed"
    case needsDecision = "needs_decision", recoveryRequired = "recovery_required"
    case operationInProgress = "operation_in_progress", dependencyUnavailable = "dependency_unavailable"
    case resyncRequired = "resync_required"
    case idempotencyConflict = "idempotency_conflict", busy, recordTooLarge = "record_too_large"
}

public enum ManagedJSON: Codable, Sendable, Equatable {
    case string(String), integer(Int), number(Double), bool(Bool), array([ManagedJSON]), object([String: ManagedJSON]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: ManagedJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([ManagedJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: Int? { if case .integer(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public static func value<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

public struct ManagedRequest: Codable, Sendable {
    public var protocolVersion: Int = 1
    public var requestId: String
    public var operation: String
    public var actor: String
    public var credential: String
    public var expectedRevision: Int?
    public var payload: [String: ManagedJSON]
    public init(requestId: String = UUID().uuidString, operation: String, actor: String, credential: String,
                expectedRevision: Int? = nil, payload: [String: ManagedJSON] = [:]) {
        self.requestId = requestId; self.operation = operation; self.actor = actor
        self.credential = credential; self.expectedRevision = expectedRevision; self.payload = payload
    }
}

public struct ManagedResponse: Codable, Sendable {
    public var requestId: String?
    public var status: String
    public var revision: Int
    public var operationId: UUID?
    public var data: ManagedJSON?
    public var error: ManagedError?
    public var retryable: Bool
    public init(requestId: String?, status: String = "completed", revision: Int = 0,
                operationId: UUID? = nil, data: ManagedJSON? = nil, error: ManagedError? = nil) {
        self.requestId = requestId; self.status = error == nil ? status : "error"
        self.revision = revision; self.operationId = operationId; self.data = data; self.error = error
        retryable = error == .busy || error == .operationInProgress || error == .staleRevision
    }
}

public struct ManagedActor: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case read, owner, coordinator, user }
    public var id: String
    public var scope: Scope
    public var credentialHash: String
    public init(id: String, scope: Scope, credentialHash: String) {
        self.id = id; self.scope = scope; self.credentialHash = credentialHash
    }
}

public struct ManagedIncarnation: Codable, Sendable, Equatable {
    public var hostId: String
    public var bootId: String
    public var pid: Int32
    public var startTime: Date
}

public struct ManagedClaim: Codable, Sendable, Identifiable {
    public var id: UUID
    public var actor: String
    public var active: Bool
    public var revision: Int
}

public struct ManagedWorkspace: Codable, Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var filesystemIdentity: String
}

public struct ManagedService: Codable, Sendable, Identifiable {
    public var id: UUID
    public var workspace: ManagedWorkspace
    public var name: String
    public var variant: String
    public var revision: Int = 1
    public var lifecycle: String = "starting"
    public var launchFingerprint: String
    public var claims: [ManagedClaim] = []
    public var keepRunning: Bool = false
    public var incarnations: [ManagedIncarnation] = []
    public var backendPort: UInt16?
    public var stablePort: UInt16?
    public var routeGeneration: Int = 0
    public var fence: UUID?
    public var treeComplete: Bool = false
    public var tailnet: ManagedTailnetRoute?
    public var transition: ManagedRouteTransition?
    public var activeClaims: [ManagedClaim] { claims.filter(\.active) }
}

public struct ManagedRouteTransition: Codable, Sendable {
    public var operationId: UUID
    public var oldBackend: UInt16
    public var newBackend: UInt16
    public var oldGeneration: Int
    public var oldTargets: [ManagedIncarnation]
    public var newTargets: [ManagedIncarnation]
    public var phase: String
}

public struct ManagedOperation: Codable, Sendable, Identifiable {
    public var id: UUID
    public var serviceId: UUID
    public var action: String
    public var revision: Int
    public var targets: [ManagedIncarnation]
    public var generation: Int
    public var actor: String
    public var phase: String
    public var outcome: String?
    public var acknowledgements: [String] = []
    public var approved: Bool = false
    public var expires: Date
}

public struct ManagedEvent: Codable, Sendable {
    public var sequence: Int
    public var serviceId: UUID?
    public var operationId: UUID?
    public var kind: String
    public var revision: Int
    public var date: Date
}

struct ManagedReplay: Codable, Sendable {
    var actor: String
    var digest: String
    var response: ManagedResponse
    var date: Date
}

struct ManagedState: Codable, Sendable {
    var schema = 1
    var revision = 0
    var lastEventSequence = 0
    var services: [ManagedService] = []
    var operations: [ManagedOperation] = []
    var events: [ManagedEvent] = []
    var replays: [String: ManagedReplay] = [:]
    var maintenance: String?
}

public enum ManagedDigest {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func keyed(_ data: Data, key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ManagedServiceName {
    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...40).contains(bytes.count), let first = bytes.first,
              (97...122).contains(first) || (48...57).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}
