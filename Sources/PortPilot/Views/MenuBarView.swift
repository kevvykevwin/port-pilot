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
            if store.filteredEntries.isEmpty {
                EmptyStateView(hasEntries: !store.entries.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    PortListView(groups: store.grouped, multiPortProjects: store.multiPortProjects)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }

            Divider()

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
        .frame(width: 320, height: 500)
        .preferredColorScheme(.dark)
    }
}
