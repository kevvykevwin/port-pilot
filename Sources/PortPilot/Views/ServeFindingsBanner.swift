import SwiftUI
import AppKit
import PortPilotCore

/// Warns about Tailscale Serve routes ("links") whose local backend is not listening.
/// Expanded by default; each row has a Copy fix button for the removal command.
struct ServeFindingsBanner: View {
    let findings: [ServeRouteFinding]
    let uncheckedCount: Int

    @State private var isExpanded = true

    private var title: String { ServeFindingsSummary.title(count: findings.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.orange)
                    Text(verbatim: title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Hides the broken links" : "Shows the broken links")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: ServeFindingsSummary.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(findings, id: \.route) { finding in
                        ServeFindingRow(route: finding.route)
                    }
                    Text(verbatim: ServeFindingsSummary.footnote(unchecked: uncheckedCount))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ServeFindingRow: View {
    let route: ServeRoute

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: route.selectorLabel)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(verbatim: route.problemDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            CopyFixButton(route: route)
        }
    }
}

/// Plain-text clipboard write shared by row actions and Copy fix.
enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Bordered "Copy fix" button: copies the route's removal command and shows
/// "Copied" for 1.5 s. Port Pilot never runs the command.
struct CopyFixButton: View {
    let route: ServeRoute

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            copyCommand()
        } label: {
            Text(copied ? "Copied" : "Copy fix")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(Text(verbatim: "Copy fix for \(route.selectorLabel)"))
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copyCommand() {
        Pasteboard.copy(route.removalCommand)
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}
