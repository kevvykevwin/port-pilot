import Foundation

public enum VSCodeExtensions {

    public static let knownExtensions: [String: String] = [
        "ms-python.vscode-pylance": "Python language server (Pylance)",
        "ms-python.python": "Python extension",
        "ms-python.debugpy": "Python debugger",
        "ms-vscode.cpptools": "C/C++ IntelliSense",
        "rust-lang.rust-analyzer": "Rust analyzer",
        "golang.go": "Go language support",
        "dbaeumer.vscode-eslint": "ESLint",
        "esbenp.prettier-vscode": "Prettier formatter",
        "ms-vscode-remote.remote-ssh": "Remote SSH",
        "ms-vscode-remote.remote-containers": "Dev Containers",
        "ms-vscode.live-server": "Live Preview server",
        "ritwickdey.liveserver": "Live Server",
        "github.copilot": "GitHub Copilot",
        "github.copilot-chat": "GitHub Copilot Chat",
    ]

    public static func extractExtensionID(from path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        for i in 0..<components.count {
            guard components[i] == "extensions" else { continue }
            guard i > 0 else { continue }

            let parent = components[i - 1]
            let isEditorDir = parent == ".vscode"
                || parent == ".vscode-insiders"
                || parent == ".cursor"

            guard isEditorDir else { continue }

            let nextIndex = i + 1
            guard nextIndex < components.count else { continue }

            let rawDirName = components[nextIndex]
            guard !rawDirName.isEmpty else { continue }

            return stripVersion(from: rawDirName)
        }

        return nil
    }

    private static func stripVersion(from rawID: String) -> String {
        var segments = rawID.split(separator: "-", omittingEmptySubsequences: false).map(String.init)

        // Only strip if the trailing segment looks like a dotted semver (e.g., "2026.1.1").
        // A bare number like "2026" alone is not stripped — it could be part of the name.
        guard segments.count > 1,
              let last = segments.last,
              isDottedVersion(last) else {
            return rawID
        }
        segments.removeLast()
        return segments.joined(separator: "-")
    }

    /// Returns true if the segment is a dotted numeric version (e.g., "2026.1.1", "1.300.0").
    /// Requires at least one dot to distinguish from bare numbers that might be part of an ID.
    private static func isDottedVersion(_ segment: String) -> Bool {
        guard !segment.isEmpty else { return false }
        let parts = segment.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}
