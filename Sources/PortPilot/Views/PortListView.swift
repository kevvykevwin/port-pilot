import SwiftUI
import PortPilotCore

struct PortListView: View {
    let store: PortStore

    var body: some View {
        let labels = ProjectDisplayName.labels(for: store.entries.compactMap { store.projectOwner(for: $0) })
        let reviewProjects = store.multiPortProjects
        let overlappingRows = store.conflictingRowIDs
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(store.grouped) { group in
                CollapsibleSection(group: group, store: store, projectDisplayNames: labels,
                                   reviewProjects: reviewProjects, overlappingRows: overlappingRows)
            }
        }
    }
}

private struct CollapsibleSection: View {
    let group: PortGroup
    let store: PortStore
    let projectDisplayNames: [String: String]
    let reviewProjects: Set<String>
    let overlappingRows: Set<String>
    @State private var isCollapsed: Bool

    init(group: PortGroup, store: PortStore, projectDisplayNames: [String: String],
         reviewProjects: Set<String>, overlappingRows: Set<String>) {
        self.group = group
        self.store = store
        self.projectDisplayNames = projectDisplayNames
        self.reviewProjects = reviewProjects
        self.overlappingRows = overlappingRows
        self._isCollapsed = State(initialValue: group.collapsedByDefault)
    }

    private var projectRoot: String? {
        guard group.id.hasPrefix("project-"), group.id != "project-Other" else { return nil }
        return String(group.id.dropFirst("project-".count))
    }

    var body: some View {
        Section {
            if !isCollapsed {
                ForEach(group.entries, id: \.rowID) { entry in
                    let root = store.projectOwner(for: entry)
                    PortRowView(
                        entry: entry,
                        isMultiPort: root.map { reviewProjects.contains($0) } ?? false,
                        isConflicting: overlappingRows.contains(entry.rowID),
                        projectLabel: root.flatMap { projectDisplayNames[$0] },
                        classification: store.classification(for: entry),
                        bindingSummary: store.bindingSummary(for: entry),
                        onCategoryChange: { store.setCategory($0, for: entry) }
                    )
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                HStack {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                    Text(group.name).font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary).textCase(nil)
                    if let root = projectRoot, store.hasExpectedServices(for: root) {
                        Image(systemName: "checkmark.circle")
                            .help("Expected services saved. New or duplicate services still flag for review.")
                    }
                    Spacer()
                    Text("\(group.entries.count)").font(.caption2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary).clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let root = projectRoot {
                    Button("Remember Current Services as Expected") {
                        store.rememberExpectedServices(for: root)
                    }
                    Button("Clear Expected Services") { store.clearExpectedServices(for: root) }
                        .disabled(!store.hasExpectedServices(for: root))
                }
            }
        }
    }
}
