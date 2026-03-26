import SwiftUI
import PortPilotCore

struct PortRowView: View {
    let entry: PortEntry
    var isMultiPort: Bool = false

    @State private var confirmingKill = false

    private static let killConfirmResetNs: UInt64 = 2_000_000_000  // 2s before button resets

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var isInfrastructure: Bool {
        PortCategory.infrastructurePorts.contains(entry.port)
    }

    private var projectLabel: String? {
        guard let path = entry.projectPath else { return nil }
        // Show just the last path component as the project name
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            // Port number
            Text(":\(entry.port)")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            // Infrastructure warning
            if isInfrastructure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Infrastructure — kill with caution")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.processName)
                    .font(.caption)
                    .lineLimit(1)

                if let desc = entry.vsCodeExtensionDescription {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    // Project tag
                    if let project = projectLabel {
                        Text(project)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    Text("pid \(entry.pid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Kill button with confirmation
            Button {
                if confirmingKill {
                    _ = ProcessKiller.terminate(pid: entry.pid)
                    confirmingKill = false
                } else {
                    confirmingKill = true
                    Task {
                        try? await Task.sleep(nanoseconds: Self.killConfirmResetNs)
                        confirmingKill = false
                    }
                }
            } label: {
                if confirmingKill {
                    Text("Kill?")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
            .buttonStyle(.borderless)
            .help(confirmingKill ? "Click again to kill process" : "Kill process \(entry.pid)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            isMultiPort
                ? RoundedRectangle(cornerRadius: 4).fill(.orange.opacity(0.08))
                : RoundedRectangle(cornerRadius: 4).fill(.clear)
        )
        .overlay(alignment: .leading) {
            if isMultiPort {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.orange)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Port")         { copy(String(entry.port)) }
            Button("Copy PID")          { copy(String(entry.pid)) }
            Button("Copy Kill Command") { copy("kill -9 \(entry.pid)") }
        }
    }
}
