import Foundation

public enum ManagedVersion {
    public static func read(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) throws -> String {
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [directory.appendingPathComponent("../Resources/VERSION"),
                          directory.appendingPathComponent("../VERSION"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("VERSION")]
        for file in candidates {
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("VERSION=") }) else { continue }
            let version = line.dropFirst("VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r"))
            if !version.isEmpty { return version }
        }
        throw ManagedError.dependencyUnavailable
    }
}
