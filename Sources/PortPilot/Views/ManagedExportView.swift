import SwiftUI
import PortPilotCore

/// Local controls for optional private notifications (PC15). Off by default. All authority is the
/// local user credential; nothing here talks to a network. Real service names appear only here.
struct ManagedExportView: View {
    let reports: [ManagedServiceReport]
    @State private var status: ManagedExportStatus?
    @State private var unavailable = false
    @State private var selected: Set<UUID> = []
    @State private var destination = ""
    @State private var consent = false
    @State private var message: String?
    @State private var inFlight = false
    @State private var generation = 0
    @State private var confirmation: Confirmation?
    private let client = ManagedClient()

    private enum Confirmation: String, Identifiable { case disable, abandon; var id: String { rawValue } }

    private var current: ManagedExportEnrollmentStatus? { status?.current }
    private var canEnroll: Bool { !selected.isEmpty && !destination.trimmingCharacters(in: .whitespaces).isEmpty && consent && !inFlight }

    private func serviceNames(_ ids: [UUID]) -> String {
        let names = ids.compactMap { id in reports.first { $0.id == id }.map { "\($0.name) · \($0.variant)" } }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private var summary: String {
        if unavailable { return "Private notifications unavailable on this helper; local management unaffected." }
        guard let current else { return "Private notifications: off" }
        switch current.display {
        case "active": return "Notifications on · \(current.selectedServices.count) services · destination \(current.destination) · epoch \(current.epoch)"
        case "revoked_shutdown_unconfirmed": return "Revoked; delivery shutdown unconfirmed"
        case "disabled_shutdown_confirmed": return current.agentTakeover ? "Disabled · shutdown confirmed by restarted agent" : "Disabled · agent shutdown confirmed"
        case "abandoned_shutdown_unconfirmed": return "Disabled · shutdown was never confirmed (replacement allowed)"
        default: return "Private notifications: off"
        }
    }

    private var stateLabel: String {
        unavailable ? "unavailable" : (current?.display.replacingOccurrences(of: "_", with: " ") ?? "off")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Private notifications").font(.caption.bold())
            Text(summary).font(.caption)
                .accessibilityLabel("Private notifications. \(summary)")
                .accessibilityValue(stateLabel)
                .accessibilityAddTraits(.updatesFrequently)
            if !unavailable {
                switch current?.display {
                case "active": activeControls
                case "revoked_shutdown_unconfirmed": revokedControls
                default: enrollmentForm
                }
            }
            if let message {
                Text(message).font(.caption).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(confirmation == .abandon ? "Replace without confirmation?" : "Disable notifications?",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if confirmation == .abandon {
                Button("Replace without confirmation", role: .destructive) { Task { await run("Replacement allowed; the old agent was never confirmed stopped.") { try $0.abandonExport($1) } } }
            } else {
                Button("Disable notifications", role: .destructive) { Task { await run("Notifications revoked. Waiting for the agent to confirm shutdown.") { try $0.disableExport($1) } } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmation == .abandon
                 ? "The agent has not confirmed it stopped. Messages it already queued or started sending may still be delivered, and cannot be recalled."
                 : "The agent loses read access immediately. Messages already being sent may still arrive. Services and claims are not changed.")
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current {
                Text("Services: \(serviceNames(current.selectedServices))").font(.caption2)
            }
            Button("Disable notifications…") { confirmation = .disable }
                .controlSize(.small).disabled(inFlight)
                .accessibilityLabel("Disable notifications for \(current.map { serviceNames($0.selectedServices) } ?? "services"), destination \(current?.destination ?? "")")
                .accessibilityValue(stateLabel)
        }
    }

    private var revokedControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current {
                Text("Services: \(serviceNames(current.selectedServices)) · destination \(current.destination)").font(.caption2)
            }
            HStack {
                if current?.controlRetired == false {
                    Button("Remove agent credential") { Task { await run("Agent credential removed. Shutdown is still unconfirmed.") { try $0.removeExportAgent($1) } } }
                        .accessibilityLabel("Remove agent credential for destination \(current?.destination ?? ""). Shutdown unconfirmed.")
                }
                Button("Replace without confirmation…") { confirmation = .abandon }
                    .accessibilityLabel("Replace without confirmation for destination \(current?.destination ?? ""). Shutdown unconfirmed.")
            }.controlSize(.small).disabled(inFlight)
        }
    }

    private var enrollmentForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            if reports.isEmpty {
                Text("Register a service first.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(reports) { report in
                Toggle(isOn: Binding(get: { selected.contains(report.id) },
                                     set: { if $0 { selected.insert(report.id) } else { selected.remove(report.id) } })) {
                    Text(verbatim: "\(report.name) · \(report.variant)").font(.caption2)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Send notifications for \(report.name), \(report.variant)")
                .accessibilityValue(selected.contains(report.id) ? "selected" : "not selected")
            }
            TextField("Destination description", text: $destination)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityLabel("Destination description")
                .accessibilityValue(destination.isEmpty ? "empty" : destination)
            Text("Exported fields: " + (status?.allowedFields.isEmpty == false ? status!.allowedFields : ManagedNotificationContract.allowedFields).joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
            Text("Service names, labels, paths, owners and URLs are not exported. Your destination description stays on this Mac.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("I reviewed the exported fields", isOn: $consent).toggleStyle(.checkbox).font(.caption2)
                .accessibilityValue(consent ? "checked" : "unchecked")
            Button("Enable notifications") { Task { await enroll() } }
                .controlSize(.small).disabled(!canEnroll)
                .accessibilityLabel("Enable notifications for \(serviceNames(Array(selected))), destination \(destination)")
                .accessibilityValue(canEnroll ? "available" : "needs a service, a destination and your review")
        }
    }

    private func refresh() async {
        generation += 1
        let mine = generation
        let client = client
        do {
            let fresh = try await Task.detached(priority: .utility) { try client.exportStatus() }.value
            guard mine == generation, !Task.isCancelled else { return }
            unavailable = fresh.exportUnavailable; status = fresh
            if fresh.current?.display == "active" { selected = []; consent = false; destination = "" }
        } catch {
            // Helper unreachable: the services section already reports that; keep the last known state.
            guard mine == generation, !Task.isCancelled else { return }
        }
    }

    private func announce(_ text: String) {
        message = text
        AccessibilityNotification.Announcement(text).post()
    }

    private func enroll() async {
        guard canEnroll else { return }
        inFlight = true; defer { inFlight = false }
        let client = client, services = Array(selected), name = destination.trimmingCharacters(in: .whitespaces)
        do {
            try await Task.detached(priority: .utility) { try client.enrollExport(services: services, destination: name) }.value
            announce("Notifications enabled for \(services.count) services, destination \(name).")
            selected = []; destination = ""; consent = false
        } catch let error as ManagedError {
            announce(error == .needsDecision ? "Finish shutting down the previous notification agent first." : "Not enabled: \(error.rawValue).")
        } catch { announce("No confirmed result from helper. Refresh before retrying.") }
        await refresh()
    }

    private func run(_ success: String, _ action: @escaping @Sendable (ManagedClient, UUID) throws -> Void) async {
        guard let id = current?.id, !inFlight else { return }
        inFlight = true; defer { inFlight = false }
        let client = client
        do {
            try await Task.detached(priority: .utility) { try action(client, id) }.value
            announce(success)
        } catch let error as ManagedError { announce("Not applied: \(error.rawValue).") }
        catch { announce("No confirmed result from helper. Refresh before retrying.") }
        await refresh()
    }
}
