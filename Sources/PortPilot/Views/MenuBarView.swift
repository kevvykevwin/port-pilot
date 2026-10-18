import SwiftUI
import PortPilotCore

struct MenuBarView: View {
    @Bindable var store: PortStore

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Search & Group Mode
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter ports...", text: $store.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Picker("Group", selection: $store.groupMode) {
                    Text("Project").tag(GroupMode.project)
                    Text("Type").tag(GroupMode.type)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)

            Divider()

            // MARK: - Port List or Empty State
            if store.scanError != nil && !store.entries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Scan failed — showing last results")
                        .font(.caption)
                    Spacer()
                    Button("Retry") {
                        Task { await store.refresh() }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            if store.filteredEntries.isEmpty {
                EmptyStateView(
                    hasEntries: !store.entries.isEmpty,
                    scanFailed: store.scanError != nil
                ) {
                    Task { await store.refresh() }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    PortListView(store: store)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 3) {
                    if let date = store.lastSuccessfulScan {
                        HStack(spacing: 4) {
                            Text(store.scanError == nil ? "Updated" : "Last success")
                            Text(date, style: .relative)
                            Text("ago")
                        }
                    } else {
                        Text(store.isScanning ? "Reading listeners…" : "No successful scan yet")
                    }
                    Text(store.lastScanSource == .libprocFallback
                         ? "Fallback scan · accessible processes only"
                         : "TCP listeners · visibility depends on permissions")
                }
                .font(.caption2)
                .foregroundStyle(store.scanError == nil ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            // MARK: - Status Bar
            HStack {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(store.listeningCount) listening port\(store.listeningCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .disabled(store.isScanning)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Quit Port Pilot")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360, height: 560)
        .preferredColorScheme(.dark)
        // The window's content view appears/disappears as the menu opens/closes.
        // Use that to run fast (2s) polling only while visible.
        .onAppear { store.setActive(true) }
        .onDisappear { store.setActive(false) }
    }
}
