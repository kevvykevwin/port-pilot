import SwiftUI
import PortPilotCore

struct PortListView: View {
    let groups: [PortGroup]
    let multiPortProjects: Set<String>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                CollapsibleSection(group: group, multiPortProjects: multiPortProjects)
            }
        }
    }
}

private struct CollapsibleSection: View {
    let group: PortGroup
    let multiPortProjects: Set<String>
    @State private var isCollapsed: Bool

    init(group: PortGroup, multiPortProjects: Set<String>) {
        self.group = group
        self.multiPortProjects = multiPortProjects
        self._isCollapsed = State(initialValue: group.collapsedByDefault)
    }

    var body: some View {
        Section {
            if !isCollapsed {
                ForEach(group.entries, id: \.id) { entry in
                    PortRowView(
                        entry: entry,
                        isMultiPort: entry.projectPath.map { multiPortProjects.contains($0) } ?? false
                    )
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(group.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(group.entries.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
        }
    }
}
