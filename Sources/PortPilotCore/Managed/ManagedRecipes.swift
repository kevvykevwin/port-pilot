import Foundation
import CryptoKit
import Darwin

/// Recipes are authenticated ciphertext outside the public registry. Secret
/// values are separately enrolled and resolved afresh before every launch.
public struct ManagedRecipes: Sendable {
    let persistence: ManagedPersistence
    let key: SymmetricKey
    public init(persistence: ManagedPersistence, key: Data) {
        self.persistence = persistence
        self.key = SymmetricKey(data: SHA256.hash(data: key))
    }
    public func save(_ launch: ManagedLaunch, fingerprint: String) throws {
        let box = try ChaChaPoly.seal(JSONEncoder().encode(launch), using: key, authenticating: Data(fingerprint.utf8))
        try persistence.write(name(fingerprint), data: box.combined)
    }
    public func load(fingerprint: String) throws -> ManagedLaunch {
        guard let bytes = try persistence.read(name(fingerprint)) else { throw ManagedError.needsDecision }
        do {
            let clear = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: bytes), using: key, authenticating: Data(fingerprint.utf8))
            return try JSONDecoder().decode(ManagedLaunch.self, from: clear)
        } catch { throw ManagedError.recoveryRequired }
    }
    private func name(_ fingerprint: String) throws -> String {
        guard fingerprint.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ManagedError.invalidInput }
        return "recipe-\(fingerprint).sealed"
    }
    public func secret(_ reference: String) throws -> String {
        guard ManagedServiceName.isValid(reference), let data = try persistence.read("secret-\(reference)"),
              data.count <= 16_384, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ManagedError.needsDecision }
        return text
    }
    public func enrollSecret(_ reference: String, from file: URL) throws {
        guard ManagedServiceName.isValid(reference) else { throw ManagedError.invalidInput }
        let data = try ManagedBoundedFile.read(file, limit: 16_384, requirePrivate: true)
        guard let value = String(data: data, encoding: .utf8), !value.contains("\0") else { throw ManagedError.invalidInput }
        try persistence.write("secret-\(reference)", data: data)
    }
}

public enum ManagedBoundedFile {
    public static func read(_ url: URL, limit: Int, requirePrivate: Bool = false) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ManagedError.invalidInput }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit,
              !requirePrivate || (info.st_uid == getuid() && info.st_mode & 0o077 == 0) else { throw ManagedError.invalidInput }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: min(limit + 1, 65_536))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ManagedError.invalidInput }
            if count == 0 { break }
            guard data.count + count <= limit else { throw ManagedError.recordTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
