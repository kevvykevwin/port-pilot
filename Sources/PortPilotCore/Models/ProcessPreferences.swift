import Foundation

/// Local, versioned user choices. UserDefaults is injected so tests never write
/// into the application's real preferences domain.
struct ProcessPreferences: Codable {
    var version = 1
    var categories: [String: PortCategory] = [:]
    var expectedServices: [String: Set<String>] = [:]

    static let storageKey = "processPreferences.v1"

    static func load(from defaults: UserDefaults?) -> ProcessPreferences {
        guard let data = defaults?.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1 else {
            return Self()
        }
        return saved
    }

    func save(to defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }
}
