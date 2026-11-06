import Foundation
import Darwin
import CryptoKit

// Optional private-notification export (spec-portpilot-private-coordination, PC05-PC18).
//
// Authority model: export credentials live in a versioned sidecar (export-state.json),
// never in actors.json, and are matched by a separate table. A credential that matches
// no legacy actor is looked up here; it can reach only the operations listed in
// `handleExport`. Export operations never touch registry.json, its revision or replays.
// Nothing in this file performs network I/O.

// MARK: - Public wire types

public enum ManagedExportScope: String, Codable, Sendable {
    case notificationRead = "notification_read", exportControl = "export_control"
}

public enum ManagedNotificationAction: String, Codable, Sendable { case stop, reroute, force }

public enum ManagedNotificationStatus: String, Codable, Sendable {
    case pendingDecision = "pending_decision", accepted, executing, completed
    case needsReview = "needs_review", denied, expired, withdrawn
}

public enum ManagedNotificationOutcome: String, Codable, Sendable { case none, verified, unverified, failed }

/// The only record shape that may leave the helper. Times are integer Unix epoch seconds.
public struct ManagedNotificationRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var serviceRef: String
    public var decisionRef: String
    public var serviceRevision: Int
    public var action: ManagedNotificationAction
    public var status: ManagedNotificationStatus
    public var outcome: ManagedNotificationOutcome
    public var routeGeneration: Int
    public var ownerCount: Int
    public var observedAt: Int
    public var expiresAt: Int
    enum CodingKeys: String, CodingKey {
        case schemaVersion, serviceRef, decisionRef, serviceRevision, action, status, outcome
        case routeGeneration, ownerCount, observedAt, expiresAt
    }
    public init(serviceRef: String, decisionRef: String, serviceRevision: Int, action: ManagedNotificationAction,
                status: ManagedNotificationStatus, outcome: ManagedNotificationOutcome, routeGeneration: Int,
                ownerCount: Int, observedAt: Int, expiresAt: Int) {
        self.serviceRef = serviceRef; self.decisionRef = decisionRef; self.serviceRevision = serviceRevision
        self.action = action; self.status = status; self.outcome = outcome; self.routeGeneration = routeGeneration
        self.ownerCount = ownerCount; self.observedAt = observedAt; self.expiresAt = expiresAt
    }
}

public struct ManagedNotificationPage: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var enrollmentEpoch: Int
    public var snapshotId: String
    /// Opaque, sealed, enrollment-bound position in the change stream. Pass it back as `after`. It is a
    /// different string on every call, so neither its value nor its growth reveals activity on other services.
    public var changeCursor: String
    /// Envelope field (not a record field). Enrollment-scoped identifier of the helper process that served
    /// this page. A change between two responses means the helper restarted: an incremental reader MUST
    /// discard its cursor and take a fresh snapshot (an `after` cursor from a previous instance is not
    /// guaranteed to line up with this instance's event history).
    public var helperInstance: String
    public var records: [ManagedNotificationRecord]
    public var nextPageToken: String?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, enrollmentEpoch, snapshotId, changeCursor, helperInstance, records, nextPageToken
    }
    public init(schemaVersion: Int = ManagedNotificationContract.pageSchema, enrollmentEpoch: Int, snapshotId: String, changeCursor: String, helperInstance: String,
                records: [ManagedNotificationRecord], nextPageToken: String?) {
        self.schemaVersion = schemaVersion; self.enrollmentEpoch = enrollmentEpoch; self.snapshotId = snapshotId
        self.changeCursor = changeCursor; self.helperInstance = helperInstance
        self.records = records; self.nextPageToken = nextPageToken
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(enrollmentEpoch, forKey: .enrollmentEpoch)
        try c.encode(snapshotId, forKey: .snapshotId); try c.encode(changeCursor, forKey: .changeCursor)
        try c.encode(helperInstance, forKey: .helperInstance)
        try c.encode(records, forKey: .records)
        try c.encode(nextPageToken, forKey: .nextPageToken)   // explicit null, never an omitted key
    }
}

/// Written once to a private file at enrollment; the agent reads it, the helper only keeps hashes.
public struct ManagedExportCredentialFile: Codable, Sendable, Equatable {
    public struct Pair: Codable, Sendable, Equatable {
        public var actor: String
        public var credential: String
    }
    public var enrollmentId: String
    public var epoch: Int
    public var notification: Pair
    public var control: Pair
}

/// Receiver-side validation, shared by the fake receiver tests and the private agent.
public enum ManagedNotificationContract {
    public static let allowedFields: [String] = [
        "schemaVersion", "serviceRef", "decisionRef", "serviceRevision", "action", "status", "outcome",
        "routeGeneration", "ownerCount", "observedAt", "expiresAt",
    ]
    static let pageFields: Set<String> = ["schemaVersion", "enrollmentEpoch", "snapshotId", "changeCursor", "helperInstance", "records", "nextPageToken"]
    public static let maxRecordBytes = 8192
    public static let maxPageRecords = 200
    public static let maxPageBytes = 1_048_576
    /// Record schema is unchanged (1). The page envelope is schema 2: `highWaterMark` (an integer that
    /// counted events on every service) became the opaque `changeCursor`.
    public static let supportedSchema = 1
    public static let pageSchema = 2
    public static let maxCursorBytes = 512

    private static func object(_ data: Data) throws -> [String: Any] {
        try ManagedWire.requireUniqueKeys(data)   // invalid UTF-8, malformed JSON, duplicate keys
        guard let value = try? JSONSerialization.jsonObject(with: data), let dictionary = value as? [String: Any] else {
            throw ManagedError.invalidInput
        }
        return dictionary
    }
    /// Strict integer: rejects booleans (CFBoolean bridges to 0/1 under `as? Int`), floating-point
    /// spellings such as `1.0` or `1e0`, and values outside Int range.
    static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number) else { return nil }
        let candidate = number.int64Value
        guard NSNumber(value: candidate).compare(number) == .orderedSame else { return nil }
        return Int(exactly: candidate)
    }
    private static let recordIntegerFields = ["schemaVersion", "serviceRevision", "routeGeneration", "ownerCount", "observedAt", "expiresAt"]

    private static func requireSupportedSchema(_ dictionary: [String: Any], expected: Int = supportedSchema) throws {
        // Checked before field names: a future schema may legitimately differ in shape.
        if let version = strictInt(dictionary["schemaVersion"]), version != expected { throw ManagedError.protocolMismatch }
    }
    private static func isRef(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.utf8.count == prefix.utf8.count + 32 &&
            value.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validateRecord(_ data: Data) throws -> ManagedNotificationRecord {
        guard data.count <= maxRecordBytes else { throw ManagedError.recordTooLarge }
        return try validateRecord(dictionary: try object(data), bytes: data)
    }
    /// `dictionary` must be the parse of `bytes`; the type checks run on the parsed numbers, which still
    /// know whether the sender wrote `true` or `1.0`.
    private static func validateRecord(dictionary: [String: Any], bytes: Data) throws -> ManagedNotificationRecord {
        try requireSupportedSchema(dictionary)
        guard Set(dictionary.keys) == Set(allowedFields) else { throw ManagedError.invalidInput }
        guard recordIntegerFields.allSatisfy({ strictInt(dictionary[$0]) != nil }) else { throw ManagedError.invalidInput }
        let record: ManagedNotificationRecord
        do { record = try JSONDecoder().decode(ManagedNotificationRecord.self, from: bytes) }
        catch { throw ManagedError.invalidInput }
        guard record.schemaVersion == supportedSchema, isRef(record.serviceRef, prefix: "svc_"),
              isRef(record.decisionRef, prefix: "dec_"), record.serviceRevision >= 0,
              record.routeGeneration >= 0, record.ownerCount >= 0 else { throw ManagedError.invalidInput }
        return record
    }
    public static func validatePage(_ data: Data) throws -> ManagedNotificationPage {
        guard data.count <= maxPageBytes else { throw ManagedError.recordTooLarge }
        return try validatePage(dictionary: try object(data))
    }
    static func validatePage(dictionary: [String: Any]) throws -> ManagedNotificationPage {
        try requireSupportedSchema(dictionary, expected: pageSchema)
        guard Set(dictionary.keys) == pageFields, let raw = dictionary["records"] as? [Any] else { throw ManagedError.invalidInput }
        guard raw.count <= maxPageRecords else { throw ManagedError.recordTooLarge }
        var records: [ManagedNotificationRecord] = []
        for element in raw {
            guard let item = element as? [String: Any],
                  let bytes = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { throw ManagedError.invalidInput }
            guard bytes.count <= maxRecordBytes else { throw ManagedError.recordTooLarge }
            records.append(try validateRecord(dictionary: item, bytes: bytes))
        }
        guard let epoch = strictInt(dictionary["enrollmentEpoch"]), let cursor = dictionary["changeCursor"] as? String,
              let snapshot = dictionary["snapshotId"] as? String, strictInt(dictionary["schemaVersion"]) == pageSchema,
              let instance = dictionary["helperInstance"] as? String,
              epoch > 0, !cursor.isEmpty, cursor.utf8.count <= maxCursorBytes, !snapshot.isEmpty, snapshot.utf8.count <= 64,
              !instance.isEmpty, instance.utf8.count <= 64 else { throw ManagedError.invalidInput }
        let token: String?
        if dictionary["nextPageToken"] is NSNull { token = nil }
        else if let string = dictionary["nextPageToken"] as? String, !string.isEmpty, string.utf8.count <= 2048 { token = string }
        else { throw ManagedError.invalidInput }
        return ManagedNotificationPage(enrollmentEpoch: epoch, snapshotId: snapshot, changeCursor: cursor, helperInstance: instance,
                                       records: records, nextPageToken: token)
    }
}

/// Polls `notifications.list` with an explicit credential file. There is no default file and no
/// fallback: an unsupported schema latches `deliveryDisabled`, after which nothing is sent.
public final class ManagedNotificationClient: @unchecked Sendable {
    /// Test seam: returns an already-decoded response. Duplicate-key and number-type checks cannot run on it.
    public typealias Transport = @Sendable (ManagedRequest) throws -> ManagedResponse
    /// Default transport: raw response bytes, validated with `ManagedWire.requireUniqueKeys` before any decoding.
    public typealias RawTransport = @Sendable (ManagedRequest) throws -> Data
    public let credentialFile: URL
    private let transport: Transport?
    private let rawTransport: RawTransport
    private let lock = NSLock()
    private var disabled = false
    public var deliveryDisabled: Bool { lock.withLock { disabled } }
    public init(root: URL, credentialFile: URL, transport: Transport? = nil, rawTransport: RawTransport? = nil) {
        self.credentialFile = credentialFile
        let socket = root.appendingPathComponent("control.sock").path
        self.transport = transport
        self.rawTransport = rawTransport ?? { try ManagedSocket.requestRaw($0, path: socket) }
    }
    public func list(pageToken: String? = nil, after: String? = nil, limit: Int? = nil) throws -> ManagedNotificationPage {
        guard !deliveryDisabled else { throw ManagedError.protocolMismatch }
        let file = try JSONDecoder().decode(ManagedExportCredentialFile.self, from: ManagedClient.readPrivateFile(credentialFile))
        var payload: [String: ManagedJSON] = [:]
        if let pageToken { payload["pageToken"] = .string(pageToken) }
        if let after { payload["after"] = .string(after) }
        if let limit { payload["limit"] = .integer(limit) }
        let request = ManagedRequest(operation: "notifications.list", actor: file.notification.actor,
                                     credential: file.notification.credential, payload: payload)
        do {
            if let transport {
                let response = try transport(request)
                if let error = response.error { throw error }
                guard let data = response.data else { throw ManagedError.invalidInput }
                return try ManagedNotificationContract.validatePage(try JSONEncoder().encode(data))
            }
            let raw = try rawTransport(request)
            try ManagedWire.requireUniqueKeys(raw)
            guard let envelope = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { throw ManagedError.invalidInput }
            if let code = envelope["error"] as? String { throw ManagedError(rawValue: code) ?? ManagedError.invalidInput }
            guard let data = envelope["data"] as? [String: Any] else { throw ManagedError.invalidInput }
            return try ManagedNotificationContract.validatePage(dictionary: data)
        } catch ManagedError.protocolMismatch {
            lock.withLock { disabled = true }
            throw ManagedError.protocolMismatch
        }
    }
}

// MARK: - Sidecar models (internal)

enum ManagedExportOperation {
    static let admin: Set<String> = ["export.enroll", "export.disable", "export.status", "export.abandon", "export.remove_agent"]
    static func isExport(_ operation: String) -> Bool {
        operation == "notifications.list" || operation.hasPrefix("export.")
    }
}

enum ManagedExportState: String, Codable, Sendable { case active, revoked, acknowledged, abandoned }

struct ManagedExportActor: Codable, Sendable, Equatable {
    var id: String
    var scope: ManagedExportScope
    var credentialHash: String
    var enrollmentId: UUID
    var epoch: Int
}

struct ManagedExportEnrollment: Codable, Sendable, Equatable {
    var id: UUID
    var epoch: Int
    var state: ManagedExportState
    var selectedServices: [UUID]
    var destinationDescription: String
    var exportedFields: [String]
    var refKey: String
    /// Latest agent process nonce that polled the control channel (see `controlPoll`). Not a secret and
    /// not part of the credential file; it only pins which process may acknowledge a revocation.
    var registeredInstance: String?
    var instanceRegisteredAt: Date?
    /// Process (PID + start time) the helper saw polling as `registeredInstance`, taken from the socket peer.
    /// Optional so sidecars written before takeover existed still decode.
    var registeredProcess: ManagedIncarnation?
    /// Set when a restarted agent took over a revoked enrollment after the helper proved the old process gone.
    var takeoverAt: Date?
    var createdAt: Date
    var revokedAt: Date?
    var shutdownChallenge: String?
    var acknowledgedAt: Date?
    var controlRetired: Bool
}

struct ManagedExportBook: Codable, Sendable, Equatable {
    var schema = 1
    var generation = 0
    var epochHighWater = 0
    var enrollments: [ManagedExportEnrollment] = []
    var actors: [ManagedExportActor] = []
}

/// Durable record that an enrollment was revoked even if `export-state.json` could not be written.
struct ManagedExportTombstone: Codable, Sendable {
    var v = 1
    var enrollmentId: UUID
    var epoch: Int
    var revokedAt: Int
    var shutdownChallenge: String
}

/// What `--capabilities` reports. Built from the same constants the helper enforces.
public struct ManagedExportCapabilities: Codable, Sendable, Equatable {
    public static let protocolVersion = 1
    public static let registrySchema = 1
    public static let exportStateSchemas = [ManagedExportStore.supportedSchema]
    public static let operations = ["notifications.list", "export.control.poll", "export.control.ack"]
    public var protocolVersion = Self.protocolVersion
    public var registrySchema = Self.registrySchema
    public var exportStateSchemas = Self.exportStateSchemas
    public var operations = Self.operations
    public static func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(Self()), as: UTF8.self)
    }
}

enum ManagedExportStore {
    static let file = "export-state.json"
    static let credentialPrefix = "export-credential-"
    static let tombstonePrefix = "export-revoked-"
    static let supportedSchema = 1
    private struct Probe: Decodable { var schema: Int }
    /// Missing file: empty book. Unsupported schema: `.protocolMismatch`. Anything unreadable:
    /// `.recoveryRequired`. A fault leaves the file untouched and never affects legacy state.
    /// A missing sidecar next to credential files or tombstones fails closed: starting from an empty
    /// book would reset `epochHighWater` and forget revocations.
    /// `pendingRevocation` is true when a tombstone upgraded an enrollment the sidecar still calls active;
    /// the registry must persist that before serving any export request.
    static func load(_ persistence: ManagedPersistence) -> (book: ManagedExportBook, fault: ManagedError?, pendingRevocation: Bool) {
        let data: Data?
        do { data = try persistence.read(file) } catch { return (ManagedExportBook(), .recoveryRequired, false) }
        guard let data else {
            let orphans = persistence.names(withPrefix: credentialPrefix) + persistence.names(withPrefix: tombstonePrefix)
            return (ManagedExportBook(), orphans.isEmpty ? nil : .recoveryRequired, false)
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return (ManagedExportBook(), .recoveryRequired, false) }
        guard probe.schema == supportedSchema else { return (ManagedExportBook(), .protocolMismatch, false) }
        guard var book = try? JSONDecoder().decode(ManagedExportBook.self, from: data) else { return (ManagedExportBook(), .recoveryRequired, false) }
        var pending = false
        for name in persistence.names(withPrefix: tombstonePrefix) {
            guard let raw = try? persistence.read(name), let stone = try? JSONDecoder().decode(ManagedExportTombstone.self, from: raw) else {
                return (ManagedExportBook(), .recoveryRequired, false)
            }
            guard let i = book.enrollments.firstIndex(where: { $0.id == stone.enrollmentId && $0.epoch == stone.epoch }) else { continue }
            if book.enrollments[i].state == .active {
                book.enrollments[i].state = .revoked
                book.enrollments[i].revokedAt = Date(timeIntervalSince1970: TimeInterval(stone.revokedAt))
                book.enrollments[i].shutdownChallenge = stone.shutdownChallenge
                pending = true
            }
        }
        return (book, nil, pending)
    }
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
    static func randomHex(_ bytes: Int) -> String { randomBytes(bytes).map { String(format: "%02x", $0) }.joined() }
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// AES-GCM sealing with a key derived (HKDF-SHA256) from the enrollment `refKey`. Each purpose has its own
/// info label, so a cursor can never open as a page token or the reverse. Wire form: base64url(nonce || ciphertext || tag).
/// Failure modes: not base64url or too short to be a sealed box -> `invalidInput`; fails to open
/// (tampered, other enrollment, other epoch, other key) -> `unauthorized`.
enum ManagedSealed {
    static let overhead = 12 + 16
    static func key(_ refKey: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: refKey), salt: Data(), info: Data(label.utf8), outputByteCount: 32)
    }
    static func seal(_ plaintext: Data, refKey: Data, label: String, aad: Data) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key(refKey, label: label), nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw ManagedError.recoveryRequired }
        return encode(combined)
    }
    static func open(_ text: String, refKey: Data, label: String, aad: Data) throws -> Data {
        guard let combined = decode(text), combined.count > overhead else { throw ManagedError.invalidInput }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key(refKey, label: label), authenticating: aad)
        } catch { throw ManagedError.unauthorized }
    }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Position in the change stream, readable only by the helper. Replaces the plain integer high-water mark.
struct ManagedChangeCursor: Codable, Equatable {
    static let label = "portpilot-export-cursor-v1"
    var v = 1
    var enrollmentId: UUID
    var epoch: Int
    var seq: Int
    init(enrollmentId: UUID, epoch: Int, seq: Int) { self.enrollmentId = enrollmentId; self.epoch = epoch; self.seq = seq }
    private static func aad(_ id: UUID, _ epoch: Int) -> Data { Data("\(label)|\(id.uuidString)|\(epoch)".utf8) }
    func seal(refKey: Data) throws -> String {
        try ManagedSealed.seal(ManagedDigest.canonical(self), refKey: refKey, label: Self.label, aad: Self.aad(enrollmentId, epoch))
    }
    static func open(_ text: String, refKey: Data, enrollmentId: UUID, epoch: Int) throws -> ManagedChangeCursor {
        guard !text.isEmpty, text.utf8.count <= ManagedNotificationContract.maxCursorBytes else { throw ManagedError.invalidInput }
        let body = try ManagedSealed.open(text, refKey: refKey, label: label, aad: aad(enrollmentId, epoch))
        guard let cursor = try? JSONDecoder().decode(ManagedChangeCursor.self, from: body), cursor.v == 1,
              cursor.enrollmentId == enrollmentId, cursor.epoch == epoch, cursor.seq >= 0 else { throw ManagedError.unauthorized }
        return cursor
    }
}

private struct ManagedPageToken: Codable {
    static let label = "portpilot-export-page-v1"
    static func aad(_ actor: String, _ id: UUID, _ epoch: Int) -> Data { Data("\(label)|\(actor)|\(id.uuidString)|\(epoch)".utf8) }
    var v = 1
    var actor: String
    var enrollmentId: UUID
    var epoch: Int
    var selectionDigest: String
    var snapshotDigest: String
    var mode: String
    var after: Int
    var hwm: Int
    var offset: Int
    var bootNonce: String
}

// MARK: - Registry integration

extension ManagedRegistry {
    // MARK: Authentication

    func authenticateExport(_ request: ManagedRequest) -> ManagedExportActor? {
        guard exportFault == nil else { return nil }
        let hash = ManagedDigest.hash(Data(request.credential.utf8))
        return exportBook.actors.first { $0.id == request.actor && ManagedExportStore.equal($0.credentialHash, hash) }
    }

    /// Live check on every request: a read credential is valid only for an active enrollment
    /// at the same epoch. Revocation therefore takes effect on the very next request.
    private func enrollment(for actor: ManagedExportActor) -> ManagedExportEnrollment? {
        exportBook.enrollments.first { $0.id == actor.enrollmentId && $0.epoch == actor.epoch }
    }

    /// Persists a revocation that so far lives only in memory or in a tombstone. Called before every
    /// export request: a restart could otherwise revive the old read credential from the sidecar.
    private func settleRevocation() throws {
        guard exportRevocationPending else { return }
        try persistExport(exportBook)
        exportRevocationPending = false
        for name in persistence.names(withPrefix: ManagedExportStore.tombstonePrefix) { try? persistence.remove(name) }
    }

    func handleExport(_ request: ManagedRequest, actor: ManagedExportActor, peer: ManagedIncarnation? = nil) throws -> ManagedResponse {
        try settleRevocation()
        switch (actor.scope, request.operation) {
        case (.notificationRead, "notifications.list"): return try listNotifications(request, actor: actor)
        case (.exportControl, "export.control.poll"): return try controlPoll(request, actor: actor, peer: peer)
        case (.exportControl, "export.control.ack"): return try controlAck(request, actor: actor)
        default: throw ManagedError.unauthorized
        }
    }

    // MARK: Persistence

    /// Writes the sidecar first; memory changes only if the write succeeded.
    private func persistExport(_ candidate: ManagedExportBook) throws {
        var next = candidate; next.generation = exportBook.generation + 1
        next.epochHighWater = max(next.epochHighWater, exportBook.epochHighWater)
        do { try persistence.write(ManagedExportStore.file, data: try ManagedDigest.canonical(next)) }
        catch { throw ManagedError.recoveryRequired }
        exportBook = next
    }

    private func strictPayload(_ request: ManagedRequest, allowed: Set<String>) throws {
        guard Set(request.payload.keys).isSubset(of: allowed) else { throw ManagedError.invalidInput }
    }
    private func enrollmentId(_ request: ManagedRequest) throws -> UUID {
        guard let raw = request.payload["enrollmentId"]?.string, let id = UUID(uuidString: raw) else { throw ManagedError.invalidInput }
        return id
    }

    // MARK: Admin operations (legacy user scope only)

    func handleExportAdmin(_ request: ManagedRequest, actor: ManagedActor?) throws -> ManagedResponse {
        guard let actor, actor.scope == .user, ManagedExportOperation.admin.contains(request.operation) else { throw ManagedError.unauthorized }
        if let fault = exportFault { throw fault }
        try settleRevocation()
        switch request.operation {
        case "export.enroll": return try enroll(request)
        case "export.disable": return try disable(request)
        case "export.abandon": return try abandon(request)
        case "export.remove_agent": return try removeAgent(request)
        default: return try exportStatus(request)
        }
    }

    private static func displayState(_ e: ManagedExportEnrollment) -> String {
        switch e.state {
        case .active: return "active"
        case .revoked: return "revoked_shutdown_unconfirmed"
        case .acknowledged: return "disabled_shutdown_confirmed"
        case .abandoned: return "abandoned_shutdown_unconfirmed"
        }
    }

    private func exportStatus(_ request: ManagedRequest) throws -> ManagedResponse {
        let seconds: (Date) -> Int = { Int($0.timeIntervalSince1970) }
        let status = ManagedExportStatus(
            exportUnavailable: false, epochHighWater: exportBook.epochHighWater,
            allowedFields: ManagedNotificationContract.allowedFields,
            enrollments: exportBook.enrollments.map { e in
                ManagedExportEnrollmentStatus(
                    id: e.id, epoch: e.epoch, state: e.state.rawValue, display: Self.displayState(e), selectedServices: e.selectedServices,
                    destination: e.destinationDescription, shutdownConfirmed: e.state == .acknowledged, controlRetired: e.controlRetired,
                    createdAt: seconds(e.createdAt), revokedAt: e.revokedAt.map(seconds), agentTakeover: e.takeoverAt != nil)
            })
        return ManagedResponse(requestId: request.requestId, revision: state.revision, data: try .value(status))
    }

    private func newActorId(prefix: String) -> String {
        while true {
            let id = prefix + UUID().uuidString.lowercased()
            if !actors.contains(where: { $0.id == id }) && !exportBook.actors.contains(where: { $0.id == id }) { return id }
        }
    }

    private func enroll(_ request: ManagedRequest) throws -> ManagedResponse {
        try strictPayload(request, allowed: ["services", "destination", "exportedFields", "consent"])
        guard case .array(let rawServices)? = request.payload["services"], (1...200).contains(rawServices.count) else { throw ManagedError.invalidInput }
        var services: [UUID] = []
        for raw in rawServices {
            guard let string = raw.string, let id = UUID(uuidString: string) else { throw ManagedError.invalidInput }
            services.append(id)
        }
        guard Set(services).count == services.count,
              services.allSatisfy({ id in state.services.contains { $0.id == id } }) else { throw ManagedError.invalidInput }
        guard let destination = request.payload["destination"]?.string, (1...80).contains(destination.utf8.count),
              !destination.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw ManagedError.invalidInput }
        guard case .array(let rawFields)? = request.payload["exportedFields"] else { throw ManagedError.invalidInput }
        let fields = rawFields.compactMap(\.string)
        guard fields.count == rawFields.count, fields.count == ManagedNotificationContract.allowedFields.count,
              Set(fields) == Set(ManagedNotificationContract.allowedFields) else { throw ManagedError.invalidInput }
        guard request.payload["consent"]?.bool == true else { throw ManagedError.invalidInput }
        guard !recoveryRequired else { throw ManagedError.recoveryRequired }
        guard state.maintenance == nil else { throw ManagedError.operationInProgress }
        // A helper replacement holds lifecycle.lock from its first step. Enrolling then could create an
        // enrollment the replacement's compatibility check never saw.
        guard try !ManagedLifecycleLock.isHeld(root: persistence.root) else { throw ManagedError.operationInProgress }
        // PC16: a replacement needs the previous enrollment fully shut (confirmed) or explicitly abandoned.
        guard !exportBook.enrollments.contains(where: { $0.state == .active || $0.state == .revoked }) else { throw ManagedError.needsDecision }

        let epoch = exportBook.epochHighWater + 1
        let enrollmentId = UUID()
        let notifyToken = ManagedExportStore.randomHex(32), controlToken = ManagedExportStore.randomHex(32)
        let notify = ManagedExportActor(id: newActorId(prefix: "export-notify-"), scope: .notificationRead,
            credentialHash: ManagedDigest.hash(Data(notifyToken.utf8)), enrollmentId: enrollmentId, epoch: epoch)
        let control = ManagedExportActor(id: newActorId(prefix: "export-control-"), scope: .exportControl,
            credentialHash: ManagedDigest.hash(Data(controlToken.utf8)), enrollmentId: enrollmentId, epoch: epoch)
        var book = exportBook
        // Older enrollments lose every credential: their agents cannot read, poll or acknowledge again.
        for i in book.enrollments.indices { book.enrollments[i].controlRetired = true }
        book.actors = [notify, control]
        book.enrollments.append(ManagedExportEnrollment(
            id: enrollmentId, epoch: epoch, state: .active, selectedServices: services, destinationDescription: destination,
            exportedFields: ManagedNotificationContract.allowedFields,
            refKey: Data(ManagedExportStore.randomBytes(32)).base64EncodedString(),
            registeredInstance: nil, instanceRegisteredAt: nil, registeredProcess: nil, takeoverAt: nil, createdAt: now(), revokedAt: nil, shutdownChallenge: nil, acknowledgedAt: nil, controlRetired: false))
        book.enrollments = Array(book.enrollments.suffix(8))
        book.epochHighWater = epoch

        let name = "export-credential-\(epoch)-\(UUID().uuidString.lowercased()).json"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let file = ManagedExportCredentialFile(enrollmentId: enrollmentId.uuidString, epoch: epoch,
            notification: .init(actor: notify.id, credential: notifyToken), control: .init(actor: control.id, credential: controlToken))
        try persistence.write(name, data: try encoder.encode(file))
        do { try persistExport(book) } catch { try? persistence.remove(name); throw error }
        for old in persistence.names(withPrefix: "export-credential-") where old != name { try? persistence.remove(old) }
        // Raw tokens are delivered only through the private file, never in the response.
        return ManagedResponse(requestId: request.requestId, revision: state.revision, data: .object([
            "enrollmentId": .string(enrollmentId.uuidString), "epoch": .integer(epoch),
            "credentialFile": .string(persistence.root.appendingPathComponent(name).path)]))
    }

    private func disable(_ request: ManagedRequest) throws -> ManagedResponse {
        try strictPayload(request, allowed: ["enrollmentId"])
        let id = try enrollmentId(request)
        guard let i = exportBook.enrollments.firstIndex(where: { $0.id == id }) else { throw ManagedError.invalidInput }
        if exportBook.enrollments[i].state == .active {
            var book = exportBook
            book.enrollments[i].state = .revoked
            book.enrollments[i].revokedAt = now()
            book.enrollments[i].shutdownChallenge = ManagedExportStore.randomHex(16)
            let revoked = book.enrollments[i]
            // Durable marker first, so a crash or write failure below cannot leave "active" as the only disk truth.
            let tombstone = ManagedExportTombstone(enrollmentId: revoked.id, epoch: revoked.epoch,
                revokedAt: Int(revoked.revokedAt?.timeIntervalSince1970 ?? 0), shutdownChallenge: revoked.shutdownChallenge ?? "")
            try? persistence.write(Self.tombstoneName(revoked.id), data: ManagedDigest.canonical(tombstone))
            do { try persistExport(book); try? persistence.remove(Self.tombstoneName(revoked.id)) }
            catch {
                // Fail closed: reads stay revoked in memory, the revocation is retried before any later
                // export request, and the credential file is removed so it cannot be replayed from disk.
                exportBook = book
                exportRevocationPending = true
                for name in persistence.names(withPrefix: "\(ManagedExportStore.credentialPrefix)\(revoked.epoch)-") { try? persistence.remove(name) }
                throw error
            }
        }
        return ManagedResponse(requestId: request.requestId, revision: state.revision, data: .object(["state": .string(exportBook.enrollments[i].state.rawValue)]))
    }

    private static func tombstoneName(_ id: UUID) -> String { ManagedExportStore.tombstonePrefix + id.uuidString.lowercased() }

    private func retireCredentials(of id: UUID, markAbandoned: Bool) throws {
        guard let i = exportBook.enrollments.firstIndex(where: { $0.id == id }) else { throw ManagedError.invalidInput }
        var book = exportBook
        book.actors.removeAll { $0.enrollmentId == id }
        book.enrollments[i].controlRetired = true
        if markAbandoned { book.enrollments[i].state = .abandoned }
        try persistExport(book)
        for name in persistence.names(withPrefix: "export-credential-\(book.enrollments[i].epoch)-") { try? persistence.remove(name) }
    }

    private func abandon(_ request: ManagedRequest) throws -> ManagedResponse {
        try strictPayload(request, allowed: ["enrollmentId", "acknowledgeUnconfirmed"])
        let id = try enrollmentId(request)
        guard request.payload["acknowledgeUnconfirmed"]?.bool == true else { throw ManagedError.invalidInput }
        guard let e = exportBook.enrollments.first(where: { $0.id == id }) else { throw ManagedError.invalidInput }
        switch e.state {
        case .revoked: try retireCredentials(of: id, markAbandoned: true)
        case .abandoned: break
        case .active, .acknowledged: throw ManagedError.needsDecision
        }
        return ManagedResponse(requestId: request.requestId, revision: state.revision, data: .object(["state": .string("abandoned")]))
    }

    private func removeAgent(_ request: ManagedRequest) throws -> ManagedResponse {
        try strictPayload(request, allowed: ["enrollmentId"])
        let id = try enrollmentId(request)
        guard let e = exportBook.enrollments.first(where: { $0.id == id }) else { throw ManagedError.invalidInput }
        guard e.state != .active else { throw ManagedError.needsDecision }   // disable first
        try retireCredentials(of: id, markAbandoned: false)   // never changes revoked -> acknowledged
        return ManagedResponse(requestId: request.requestId, revision: state.revision, data: .object(["state": .string(e.state.rawValue)]))
    }

    // MARK: Control operations (export_control scope)
    //
    // Agent contract: the private agent MUST call `export.control.poll` with a fresh per-process nonce
    // (`instance`) at startup and before its first dispatch. An agent that never polled never dispatched, so
    // after revocation its first poll may still register without it holding any queue.
    //
    // Control credential lifetime: poll and ack stay usable after an acknowledgement, for idempotent retry
    // of a lost ack response. That wins over "retired after acknowledgement": the credential is retired
    // only by replacement (a newer enrollment), `export.remove_agent` or `export.abandon`.

    private static func validInstance(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func controlEnrollment(_ request: ManagedRequest, actor: ManagedExportActor, allowed: Set<String>) throws -> (ManagedExportEnrollment, String) {
        try strictPayload(request, allowed: allowed)
        guard let instance = request.payload["instance"]?.string, Self.validInstance(instance) else { throw ManagedError.invalidInput }
        guard let e = enrollment(for: actor), !e.controlRetired else { throw ManagedError.unauthorized }
        return (e, instance)
    }

    /// While active the latest polling instance is the registered one (a restarted agent replaces it).
    /// Once revoked the registration is frozen, with one exception: a restarted agent may take over, but only
    /// when the helper itself proves the registered process is gone. The proof is the helper's own process
    /// lookup of the PID recorded from the socket peer at the previous poll (never an agent claim), and the
    /// successor's identity also comes from the socket peer. A hung-but-alive predecessor blocks takeover.
    /// The challenge is not rotated on takeover: the predecessor is dead, so it cannot use the old one, and
    /// the successor must still present it plus the epoch and its own instance to acknowledge.
    private func controlPoll(_ request: ManagedRequest, actor: ManagedExportActor, peer: ManagedIncarnation?) throws -> ManagedResponse {
        var (e, instance) = try controlEnrollment(request, actor: actor, allowed: ["instance"])
        let sameInstance = e.registeredInstance == instance
        var takeover = false
        if !sameInstance {
            if e.state != .active, e.registeredInstance != nil {
                guard e.state == .revoked, let recorded = e.registeredProcess, let peer,
                      identity(recorded.pid) != recorded else { throw ManagedError.unauthorized }
                takeover = true
            }
        }
        // Record the process on registration, takeover, and whenever the peer changed (persist only on change).
        // Acknowledged enrollments keep their frozen registration.
        let refreshProcess = sameInstance && e.state != .acknowledged && peer != nil && e.registeredProcess != peer
        if !sameInstance || refreshProcess {
            guard let i = exportBook.enrollments.firstIndex(where: { $0.id == e.id }) else { throw ManagedError.unauthorized }
            var book = exportBook
            if !sameInstance {
                book.enrollments[i].registeredInstance = instance
                book.enrollments[i].instanceRegisteredAt = now()
            }
            book.enrollments[i].registeredProcess = peer
            if takeover { book.enrollments[i].takeoverAt = now() }
            try persistExport(book)
            e = book.enrollments[i]
        }
        var data: [String: ManagedJSON] = [
            "protocolVersion": .integer(1), "notificationSchema": .integer(ManagedNotificationContract.pageSchema), "enrollmentId": .string(e.id.uuidString),
            "epoch": .integer(e.epoch), "state": .string(e.state.rawValue), "acknowledged": .bool(e.state == .acknowledged)]
        if e.state == .revoked || e.state == .acknowledged, let challenge = e.shutdownChallenge { data["challenge"] = .string(challenge) }
        return ManagedResponse(requestId: request.requestId, revision: 0, data: .object(data))
    }

    private func controlAck(_ request: ManagedRequest, actor: ManagedExportActor) throws -> ManagedResponse {
        let (e, instance) = try controlEnrollment(request, actor: actor, allowed: ["instance", "epoch", "challenge"])
        guard let registered = e.registeredInstance, ManagedExportStore.equal(registered, instance) else { throw ManagedError.unauthorized }
        guard request.payload["epoch"]?.integer == e.epoch else { throw ManagedError.unauthorized }
        guard let challenge = request.payload["challenge"]?.string, let expected = e.shutdownChallenge,
              e.state == .revoked || e.state == .acknowledged,
              ManagedExportStore.equal(challenge, expected) else { throw ManagedError.staleRevision }
        if e.state == .revoked {
            var book = exportBook
            guard let i = book.enrollments.firstIndex(where: { $0.id == e.id }) else { throw ManagedError.unauthorized }
            book.enrollments[i].state = .acknowledged
            book.enrollments[i].acknowledgedAt = now()
            try persistExport(book)   // durable before the agent is told shutdown is confirmed
        }
        return ManagedResponse(requestId: request.requestId, revision: 0, data: .object(["acknowledged": .bool(true)]))
    }

    // MARK: notifications.list

    private enum Mode: String { case snapshot, changes }

    private func ref(_ prefix: String, _ label: String, _ id: UUID, key: Data) -> String {
        prefix + String(ManagedDigest.keyed(Data("\(label)|\(id.uuidString)".utf8), key: key).prefix(32))
    }

    static func notificationStatus(of operation: ManagedOperation, service: ManagedService?, now: Date, uptime: TimeInterval,
                                   deadline: TimeInterval?) -> ManagedNotificationStatus {
        switch operation.phase {
        case "proposed", "authorized":
            // Wall clock rollback and helper restart clear/lose the monotonic deadline, so an
            // expired decision can never come back to life.
            if operation.expires <= now { return .expired }
            guard let deadline, deadline > uptime else { return .expired }
            guard let service, service.revision == operation.revision, service.incarnations == operation.targets,
                  service.routeGeneration == operation.generation else { return .withdrawn }
            return operation.phase == "proposed" ? .pendingDecision : .accepted
        case "fenced", "signal_sent", "preparing", "ready", "switched", "observing", "retiring_old", "rolling_back": return .executing
        case "completed": return .completed
        case "denied": return .denied
        default: return .needsReview
        }
    }

    static func notificationOutcome(_ raw: String?) -> ManagedNotificationOutcome {
        guard let raw else { return .none }
        if raw == "exit_verified" || raw.hasPrefix("route_verified") { return .verified }
        if raw.contains("unverified") || raw.contains("retained") || raw.contains("timeout") { return .unverified }
        if raw == "identity_or_signal_failed" || raw == "no_healthy_backend" || raw.hasPrefix("preparation_failed") { return .failed }
        return .unverified   // never export the raw string
    }

    private func project(_ operation: ManagedOperation, key: Data) -> ManagedNotificationRecord? {
        guard let action = ManagedNotificationAction(rawValue: operation.action) else { return nil }
        let service = state.services.first { $0.id == operation.serviceId }
        let status = Self.notificationStatus(of: operation, service: service, now: now(), uptime: uptime(),
                                             deadline: approvalDeadlines[operation.id])
        return ManagedNotificationRecord(
            serviceRef: ref("svc_", "service", operation.serviceId, key: key), decisionRef: ref("dec_", "decision", operation.id, key: key),
            serviceRevision: operation.revision, action: action, status: status, outcome: Self.notificationOutcome(operation.outcome),
            routeGeneration: operation.generation, ownerCount: service?.activeClaims.count ?? 0,
            observedAt: Int(now().timeIntervalSince1970), expiresAt: Int(operation.expires.timeIntervalSince1970))
    }

    private func records(mode: Mode, after: Int, hwm: Int, enrollment e: ManagedExportEnrollment, key: Data) -> [ManagedNotificationRecord] {
        let selected = Set(e.selectedServices)
        var candidates = state.operations.filter { selected.contains($0.serviceId) }
        if mode == .changes {
            var operations = Set<UUID>(), services = Set<UUID>()
            for event in state.events where event.sequence > after && event.sequence <= hwm {
                if let id = event.operationId, event.kind.hasPrefix("operation.") { operations.insert(id) }
                else if let id = event.serviceId {
                    // A service change can withdraw a decision without any operation event.
                    services.insert(id)
                    if let id = event.operationId { operations.insert(id) }
                }
            }
            candidates = candidates.filter { operations.contains($0.id) || (services.contains($0.serviceId) && ["proposed", "authorized"].contains($0.phase)) }
        }
        var result = candidates.compactMap { project($0, key: key) }
        if mode == .snapshot {
            result = result.filter { [.pendingDecision, .accepted, .executing, .needsReview].contains($0.status) }
        }
        return result.sorted { $0.decisionRef < $1.decisionRef }
    }

    private func digest(_ records: [ManagedNotificationRecord], key: Data) throws -> String {
        let stable = records.map { record -> ManagedNotificationRecord in var r = record; r.observedAt = 0; return r }
        return ManagedDigest.keyed(try ManagedDigest.canonical(stable), key: key)
    }

    private func listNotifications(_ request: ManagedRequest, actor: ManagedExportActor) throws -> ManagedResponse {
        guard let e = enrollment(for: actor), e.state == .active, let key = Data(base64Encoded: e.refKey) else { throw ManagedError.unauthorized }
        guard !recoveryRequired else { throw ManagedError.recoveryRequired }
        try strictPayload(request, allowed: ["pageToken", "after", "limit"])
        guard request.payload["pageToken"] == nil || request.payload["after"] == nil else { throw ManagedError.invalidInput }
        var limit = ManagedNotificationContract.maxPageRecords
        if let value = request.payload["limit"] {
            guard let n = value.integer, (1...ManagedNotificationContract.maxPageRecords).contains(n) else { throw ManagedError.invalidInput }
            limit = n
        }
        let selection = ManagedDigest.keyed(
            Data(e.selectedServices.map(\.uuidString).sorted().joined(separator: ",").utf8), key: key)
        let firstRetained = state.events.first?.sequence ?? state.lastEventSequence + 1
        var mode = Mode.snapshot, after = 0, hwm = state.lastEventSequence, offset = 0
        var tokenDigest: String?
        if let raw = request.payload["pageToken"] {
            guard let text = raw.string, text.utf8.count <= 2048 else { throw ManagedError.invalidInput }
            // Sealed (AES-GCM), not just signed: the agent cannot read after/hwm/offset. Opening fails for
            // tampering, another actor, enrollment, epoch or key.
            let body = try ManagedSealed.open(text, refKey: key, label: ManagedPageToken.label, aad: ManagedPageToken.aad(actor.id, e.id, e.epoch))
            guard let token = try? JSONDecoder().decode(ManagedPageToken.self, from: body), token.v == 1,
                  let parsedMode = Mode(rawValue: token.mode), token.offset >= 0, token.after >= 0 else { throw ManagedError.invalidInput }
            guard token.actor == actor.id, token.enrollmentId == e.id, token.epoch == e.epoch, token.selectionDigest == selection else { throw ManagedError.unauthorized }
            guard token.bootNonce == exportBootNonce else { throw ManagedError.resyncRequired }   // helper restarted
            mode = parsedMode; after = token.after; hwm = token.hwm; offset = token.offset; tokenDigest = token.snapshotDigest
        } else if let value = request.payload["after"] {
            guard let text = value.string else { throw ManagedError.invalidInput }
            mode = .changes
            after = try ManagedChangeCursor.open(text, refKey: key, enrollmentId: e.id, epoch: e.epoch).seq
        }
        if mode == .changes, after < firstRetained - 1 || after > state.lastEventSequence { throw ManagedError.resyncRequired }
        let all = records(mode: mode, after: after, hwm: hwm, enrollment: e, key: key)
        let snapshotDigest = try digest(all, key: key)
        if let tokenDigest {
            // Anything that changed under the cursor invalidates it; the agent restarts without advancing.
            guard ManagedExportStore.equal(tokenDigest, snapshotDigest), offset <= all.count else { throw ManagedError.resyncRequired }
        }
        let budget = ManagedWire.responseLimit - 16 * 1024
        var page: [ManagedNotificationRecord] = [], size = 0
        for record in all.dropFirst(offset) {
            let bytes = try ManagedDigest.canonical(record).count
            guard bytes <= ManagedNotificationContract.maxRecordBytes else { throw ManagedError.recordTooLarge }
            if page.count >= limit || size + bytes + 1 > budget { break }
            page.append(record); size += bytes + 1
        }
        var next: ManagedJSON = .null
        if offset + page.count < all.count {
            let token = ManagedPageToken(actor: actor.id, enrollmentId: e.id, epoch: e.epoch, selectionDigest: selection,
                snapshotDigest: snapshotDigest, mode: mode.rawValue, after: after, hwm: hwm, offset: offset + page.count, bootNonce: exportBootNonce)
            next = .string(try ManagedSealed.seal(try ManagedDigest.canonical(token), refKey: key, label: ManagedPageToken.label,
                                                  aad: ManagedPageToken.aad(actor.id, e.id, e.epoch)))
        }
        let changeCursor = try ManagedChangeCursor(enrollmentId: e.id, epoch: e.epoch, seq: hwm).seal(refKey: key)
        // revision 0: the registry revision counts changes to every service, selected or not.
        return ManagedResponse(requestId: request.requestId, revision: 0, data: .object([
            "schemaVersion": .integer(ManagedNotificationContract.pageSchema), "enrollmentEpoch": .integer(e.epoch),
            "snapshotId": .string(String(snapshotDigest.prefix(16))),
            "changeCursor": .string(changeCursor),
            "helperInstance": .string(String(ManagedDigest.keyed(Data("helper|\(exportBootNonce)".utf8), key: key).prefix(16))),
            "records": .array(try page.map { try .value($0) }), "nextPageToken": next]))
    }
}

// MARK: - Local UI client (user credential only)

public struct ManagedExportEnrollmentStatus: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var epoch: Int
    public var state: String
    public var display: String
    public var selectedServices: [UUID]
    public var destination: String
    public var shutdownConfirmed: Bool
    public var controlRetired: Bool
    public var createdAt: Int
    public var revokedAt: Int?
    /// True when a restarted agent confirmed shutdown after the helper proved the original process had exited.
    public var agentTakeover: Bool
    public init(id: UUID, epoch: Int, state: String, display: String, selectedServices: [UUID], destination: String,
                shutdownConfirmed: Bool, controlRetired: Bool, createdAt: Int = 0, revokedAt: Int? = nil, agentTakeover: Bool = false) {
        self.agentTakeover = agentTakeover
        self.id = id; self.epoch = epoch; self.state = state; self.display = display; self.selectedServices = selectedServices
        self.destination = destination; self.shutdownConfirmed = shutdownConfirmed; self.controlRetired = controlRetired
        self.createdAt = createdAt; self.revokedAt = revokedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, epoch, state, display, selectedServices, destination, shutdownConfirmed, controlRetired, createdAt, revokedAt, agentTakeover
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); epoch = try c.decode(Int.self, forKey: .epoch)
        state = try c.decode(String.self, forKey: .state); display = try c.decode(String.self, forKey: .display)
        selectedServices = try c.decode([UUID].self, forKey: .selectedServices); destination = try c.decode(String.self, forKey: .destination)
        shutdownConfirmed = try c.decode(Bool.self, forKey: .shutdownConfirmed); controlRetired = try c.decode(Bool.self, forKey: .controlRetired)
        createdAt = try c.decode(Int.self, forKey: .createdAt); revokedAt = try c.decodeIfPresent(Int.self, forKey: .revokedAt)
        agentTakeover = try c.decodeIfPresent(Bool.self, forKey: .agentTakeover) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(epoch, forKey: .epoch); try c.encode(state, forKey: .state)
        try c.encode(display, forKey: .display); try c.encode(selectedServices, forKey: .selectedServices)
        try c.encode(destination, forKey: .destination); try c.encode(shutdownConfirmed, forKey: .shutdownConfirmed)
        try c.encode(controlRetired, forKey: .controlRetired); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(revokedAt, forKey: .revokedAt)   // explicit null, as the hand-built JSON did
        try c.encode(agentTakeover, forKey: .agentTakeover)
    }
}

public struct ManagedExportStatus: Codable, Sendable, Equatable {
    public var exportUnavailable: Bool
    public var epochHighWater: Int
    public var allowedFields: [String]
    public var enrollments: [ManagedExportEnrollmentStatus]
    public init(exportUnavailable: Bool, epochHighWater: Int = 0, allowedFields: [String], enrollments: [ManagedExportEnrollmentStatus]) {
        self.exportUnavailable = exportUnavailable; self.epochHighWater = epochHighWater
        self.allowedFields = allowedFields; self.enrollments = enrollments
    }
    /// The newest enrollment decides what the UI offers; older ones are history.
    public var current: ManagedExportEnrollmentStatus? { enrollments.max { $0.epoch < $1.epoch } }
}

extension ManagedClient {
    /// Unavailable (unknown schema / corrupt sidecar) is reported as a value, not an error, so the
    /// UI can say so while local management stays usable.
    public func exportStatus() throws -> ManagedExportStatus {
        let response = try request(operation: "export.status")
        if let error = response.error {
            if error == .protocolMismatch || error == .recoveryRequired {
                return ManagedExportStatus(exportUnavailable: true, allowedFields: [], enrollments: [])
            }
            throw error
        }
        guard let data = response.data else { throw ManagedError.invalidInput }
        return try JSONDecoder().decode(ManagedExportStatus.self, from: JSONEncoder().encode(data))
    }
    public func enrollExport(services: [UUID], destination: String) throws {
        let response = try request(operation: "export.enroll", payload: [
            "services": .array(services.map { .string($0.uuidString) }), "destination": .string(destination),
            "exportedFields": .array(ManagedNotificationContract.allowedFields.map { .string($0) }), "consent": .bool(true)])
        if let error = response.error { throw error }
    }
    public func disableExport(_ id: UUID) throws { try exportAdmin("export.disable", id) }
    public func removeExportAgent(_ id: UUID) throws { try exportAdmin("export.remove_agent", id) }
    public func abandonExport(_ id: UUID) throws { try exportAdmin("export.abandon", id, extra: ["acknowledgeUnconfirmed": .bool(true)]) }
    private func exportAdmin(_ operation: String, _ id: UUID, extra: [String: ManagedJSON] = [:]) throws {
        var payload = extra; payload["enrollmentId"] = .string(id.uuidString)
        if let error = try request(operation: operation, payload: payload).error { throw error }
    }
}
