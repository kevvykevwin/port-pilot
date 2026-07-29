import SwiftUI
import PortPilotCore

struct PortRowView: View {
    let entry: PortEntry
    var isMultiPort: Bool = false
    var isConflicting: Bool = false

    private enum KillState: Equatable {
        case idle
        case confirming
        case terminating
        case forceKillNeeded
        case forceKilling
        case terminated
        case permissionDenied
        case staleProcess
        case processGone
        case identityUnavailable
        case failed(String)
    }

    @State private var killState: KillState = .idle
    @State private var killConfirmResetTask: Task<Void, Never>?
    @State private var killTask: Task<Void, Never>?

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

    private var killHelp: String {
        switch killState {
        case .idle:
            return "Kill process \(entry.pid)"
        case .confirming:
            return "Click again to terminate process"
        case .terminating:
            return "Waiting for process to exit"
        case .forceKillNeeded:
            return "Process ignored SIGTERM; click to send SIGKILL"
        case .forceKilling:
            return "Force killing process"
        case .terminated:
            return "Process terminated"
        case .permissionDenied:
            return "Permission denied"
        case .staleProcess:
            return "PID belongs to a different process; no signal was sent"
        case .processGone:
            return "Process already exited"
        case .identityUnavailable:
            return "Could not verify current process identity; no further signal was sent"
        case .failed(let message):
            return "Termination failed: \(message)"
        }
    }

    private func beginConfirmation() {
        guard killTask == nil else { return }

        killState = .confirming
        killConfirmResetTask?.cancel()
        killConfirmResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.killConfirmResetNs)
            guard !Task.isCancelled else { return }
            killState = .idle
            killConfirmResetTask = nil
        }
    }

    private func beginGracefulTermination() {
        guard killTask == nil else { return }

        killConfirmResetTask?.cancel()
        killConfirmResetTask = nil
        killState = .terminating
        killTask = Task { @MainActor in
            let result = await ProcessKiller.terminateWithGrace(
                pid: entry.pid,
                expectedStartTime: entry.processStartTime
            )
            guard !Task.isCancelled else { return }
            apply(result)
            killTask = nil
        }
    }

    private func beginForceKill() {
        guard killTask == nil, killState == .forceKillNeeded else { return }

        killState = .forceKilling
        let pid = entry.pid
        let expectedStartTime = entry.processStartTime
        killTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let result = ProcessKiller.forceKill(
                pid: pid,
                expectedStartTime: expectedStartTime
            )
            guard !Task.isCancelled else { return }
            apply(result)
            killTask = nil
        }
    }

    private func apply(_ result: KillResult) {
        switch result {
        case .terminated:
            killState = .terminated
        case .forceKillNeeded:
            killState = .forceKillNeeded
        case .permissionDenied:
            killState = .permissionDenied
        case .processGone:
            killState = .processGone
        case .staleProcess:
            killState = .staleProcess
        case .identityUnavailable:
            killState = .identityUnavailable
        case .failed(let message):
            killState = .failed(message)
        }
    }

    private func handleKillButton() {
        switch killState {
        case .idle:
            beginConfirmation()
        case .confirming:
            beginGracefulTermination()
        case .forceKillNeeded:
            beginForceKill()
        case .terminating, .forceKilling:
            break
        case .terminated, .permissionDenied, .staleProcess, .processGone,
             .identityUnavailable, .failed:
            killState = .idle
        }
    }

    @ViewBuilder
    private var killButtonLabel: some View {
        switch killState {
        case .idle:
            Image(systemName: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red.opacity(0.7))
        case .confirming:
            statusLabel("Kill?", color: .red, filled: true)
        case .terminating:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 42)
        case .forceKillNeeded:
            statusLabel("Force?", color: .red, filled: true)
        case .forceKilling:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 42)
        case .terminated:
            statusLabel("Stopped", color: .green)
        case .permissionDenied:
            statusLabel("Denied", color: .orange)
        case .staleProcess:
            statusLabel("Changed", color: .orange)
        case .processGone:
            statusLabel("Gone", color: .secondary)
        case .identityUnavailable:
            statusLabel("Unverified", color: .orange)
        case .failed:
            statusLabel("Failed", color: .red)
        }
    }

    private func statusLabel(_ text: String, color: Color, filled: Bool = false) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(filled ? color : color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
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

            // Conflict warning
            if isConflicting {
                Image(systemName: "exclamationmark.2")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help("Port conflict — multiple processes on this port")
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
                handleKillButton()
            } label: {
                killButtonLabel
            }
            .buttonStyle(.borderless)
            .disabled(killState == .terminating || killState == .forceKilling)
            .help(killHelp)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4).fill(
                isConflicting ? Color.red.opacity(0.08)
                : isMultiPort ? Color.orange.opacity(0.08)
                : Color.clear
            )
        )
        .overlay(alignment: .leading) {
            if isConflicting || isMultiPort {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isConflicting ? Color.red : Color.orange)
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
        .onDisappear {
            killConfirmResetTask?.cancel()
            killConfirmResetTask = nil
            killTask?.cancel()
            killTask = nil
        }
    }
}
