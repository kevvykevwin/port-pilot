import SwiftUI

struct EmptyStateView: View {
    /// Whether the store has entries (but search filtered them all out)
    let hasEntries: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lighthouse.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            if hasEntries {
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
