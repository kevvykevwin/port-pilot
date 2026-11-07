import SwiftUI
import PortPilotCore

/// Helper failure is isolated from the existing scanner and its inventory.
struct ManagedServicesView: View {
    var onReports: ([ManagedServiceReport]) -> Void = { _ in }
    @State private var reports: [ManagedServiceReport] = []
    @State private var available = false
    @State private var loading = true
    @State private var lastRead: Date?
    @State private var actionMessage: String?
    @State private var expanded = false
    @State private var refreshGeneration = 0
    @State private var actionInFlight = false
    @State private var operations: [ManagedOperation] = []
    @State private var actor: String?
    @State private var confirmation: DecisionConfirmation?
    private let client = ManagedClient()

    private struct DecisionConfirmation: Identifiable {
        let id = UUID()
        let service: ManagedServiceReport
        let operation: ManagedOperation?
        let action: String
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if loading { ProgressView("Reading managed services…").controlSize(.small) }
                if !available {
                    Text("Managed helper unavailable. Listener scanning remains active.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let lastRead { Text("Last managed update: \(lastRead, style: .relative) ago · stale").font(.caption2) }
                }
                if available && reports.isEmpty { Text("No registered services.").font(.caption).foregroundStyle(.secondary) }
                ForEach(reports) { service in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: "\(service.name) · \(service.variant)").font(.caption.bold())
                            Spacer()
                            Text(verbatim: service.lifecycle.replacingOccurrences(of: "_", with: " ")).font(.caption2)
                        }
                        Text(verbatim: service.workspace.path).font(.caption2).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "Confirmed owners: " + (service.activeClaims.isEmpty ? "none" : service.activeClaims.map(\.actor).joined(separator: ", ")))
                            .font(.caption2).textSelection(.enabled)
                        if let port = service.stablePort {
                            Text(verbatim: "Preview: http://127.0.0.1:\(port)")
                                .font(.caption2).textSelection(.enabled)
                        }
                        if let port = service.backendPort { Text(verbatim: "Backend: :\(port) · generation \(service.routeGeneration)").font(.caption2) }
                        if let route = service.tailnet {
                            Text(verbatim: route.endpoint).font(.caption2).textSelection(.enabled)
                            Text(route.verified ? "Tailnet configuration verified · device reachability untested" : "Tailnet route unverified · configuration drift or unavailable")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if !service.treeComplete {
                            Text("Process tree unverified · automatic cleanup unavailable").font(.caption2).foregroundStyle(.secondary)
                        }
                        Button(service.keepRunning ? "Remove keep override" : "Keep running") {
                            Task { await keep(service) }
                        }
                        .controlSize(.small)
                        .disabled(!available || actionInFlight || service.fence != nil || !["running", "release_pending"].contains(service.lifecycle))
                        .accessibilityLabel("\(service.keepRunning ? "Remove keep override for" : "Keep running") \(service.name), \(service.variant)")
                        HStack {
                            if let claim = service.activeClaims.first(where: { $0.actor == actor }) {
                                Button("Release my claim") {
                                    Task { await perform("claim.release", service: service, payload: ["claimId": .string(claim.id.uuidString)]) }
                                }
                            } else {
                                Button("Claim for me") { Task { await perform("claim.acquire", service: service) } }
                                    .disabled(!["running", "release_pending"].contains(service.lifecycle))
                            }
                            Button("Review stop…") { confirmation = DecisionConfirmation(service: service, operation: nil, action: "stop") }
                            Button("Review move…") { confirmation = DecisionConfirmation(service: service, operation: nil, action: "reroute") }
                                .disabled(service.transition != nil || service.lifecycle != "running")
                        }
                        .controlSize(.small)
                        .disabled(!available || actionInFlight || service.fence != nil || service.lifecycle == "stopped")
                        if service.lifecycle == "stopping" {
                            Button("Review force stop…") { confirmation = DecisionConfirmation(service: service, operation: nil, action: "force") }
                                .controlSize(.small).disabled(!available || actionInFlight)
                        }
                        ForEach(operations.filter { $0.serviceId == service.id && $0.revision == service.revision && ["proposed", "authorized"].contains($0.phase) && $0.expires > Date() }) { operation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pending \(operation.action) · revision \(operation.revision)").font(.caption.bold())
                                Text("Targets: \(operation.targets.map { String($0.pid) }.joined(separator: ", ")) · generation \(operation.generation)").font(.caption2)
                                Text("Expires \(operation.expires, style: .relative)").font(.caption2)
                                HStack {
                                    if operation.phase == "proposed" {
                                        Button("Deny") {
                                            Task { await perform("decision.resolve", service: service, payload: ["operationId": .string(operation.id.uuidString), "approved": .bool(false)]) }
                                        }
                                    }
                                    Button(operation.approved ? "Review execution…" : "Review approval…") {
                                        confirmation = DecisionConfirmation(service: service, operation: operation, action: operation.action)
                                    }
                                }.controlSize(.small).disabled(!available || actionInFlight)
                            }
                        }
                        if let latest = operations.last(where: { $0.serviceId == service.id && $0.phase == "needs_review" }), let outcome = latest.outcome {
                            Text(verbatim: "Review needed: " + outcome.replacingOccurrences(of: "_", with: " "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    Divider()
                }
                ManagedExportView(reports: reports)
                if let actionMessage { Text(actionMessage).font(.caption).accessibilityAddTraits(.updatesFrequently) }
                Button("Refresh managed services") { Task { await refresh() } }.controlSize(.small)
            }
            .padding(.top, 6)
            }.frame(maxHeight: 260)
        } label: {
            Text(available ? "Managed services (\(reports.count))" : "Managed services · unavailable").font(.caption.bold())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .confirmationDialog("Confirm managed process action", item: $confirmation) { decision in
            Button(decision.operation == nil ? "Create \(decision.action) proposal" : decision.operation?.approved == true ? "Execute \(decision.action)" : "Approve \(decision.action)", role: .destructive) {
                Task { await confirm(decision) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { decision in
            Text("\(decision.service.name) · \(decision.service.variant), revision \(decision.service.revision). This affects the recorded processes used by: \(decision.service.activeClaims.map(\.actor).joined(separator: ", ")). \(decision.action == "reroute" ? "A move starts a parallel backend and switches new preview connections after health checks. The old backend remains for review." : decision.action == "force" ? "Force stop cannot allow the processes to save their work." : "A stop sends a graceful termination signal.") Unverified descendants may remain running.")
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let client = client
        do {
            let fresh = try await Task.detached(priority: .utility) { (try client.services(), try client.operations(), try client.actor()) }.value
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            reports = fresh.0; operations = fresh.1; actor = fresh.2; available = true; lastRead = Date()
            onReports(fresh.0)
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            available = false
            // Stale associations must not keep disabling the port list's kill buttons.
            onReports([])
        }
        loading = false
    }
    private func perform(_ operation: String, service: ManagedServiceReport, payload: [String: ManagedJSON] = [:]) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            let client = client
            var values = payload; values["serviceId"] = .string(service.id.uuidString)
            let submitted = values
            let response = try await Task.detached(priority: .utility) {
                try client.request(operation: operation, revision: service.revision, payload: submitted)
            }.value
            actionMessage = response.error.map { "Request not applied: \($0.rawValue). Refresh and review the current service." } ??
                (response.status == "accepted" ? "Operation accepted; waiting for verified outcome." : "Decision saved.")
        } catch { actionMessage = "No confirmed result from helper. Refresh before retrying." }
        await refresh()
    }
    private func confirm(_ decision: DecisionConfirmation) async {
        if let operation = decision.operation {
            await perform(operation.approved ? "operation.execute" : "decision.resolve", service: decision.service,
                          payload: ["operationId": .string(operation.id.uuidString), "approved": .bool(true)])
        } else {
            // Creating a proposal is non-destructive. Approval remains a separate
            // review of the helper's exact targets and revision on the next read.
            await perform("operation.propose", service: decision.service, payload: ["action": .string(decision.action)])
        }
    }
    private func keep(_ service: ManagedServiceReport) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        let client = client
        do {
            let response = try await Task.detached(priority: .utility) {
                try client.request(operation: "service.keep", revision: service.revision,
                                   payload: ["serviceId": .string(service.id.uuidString), "keep": .bool(!service.keepRunning)])
            }.value
            actionMessage = response.error.map { "Request not applied: \($0.rawValue)" } ?? "Keep preference saved."
        } catch { actionMessage = "Helper unavailable; keep preference was not changed." }
        await refresh()
    }
}
