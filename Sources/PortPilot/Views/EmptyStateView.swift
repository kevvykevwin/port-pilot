import SwiftUI

struct EmptyStateView: View {
    /// Whether the store has entries (but search filtered them all out)
    let hasEntries: Bool
    let scanFailed: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lighthouse.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            if scanFailed && !hasEntries {
                Text("Unable to scan ports")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Check access and try scanning again")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry", action: retry)
                    .controlSize(.small)
            } else if hasEntries {
                Text("No matching ports")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No listening ports detected")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Start a dev server to see it here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
