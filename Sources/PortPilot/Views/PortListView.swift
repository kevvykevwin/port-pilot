import SwiftUI
import PortPilotCore

struct PortListView: View {
    let groups: [PortGroup]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries, id: \.id) { entry in
                        PortRowView(entry: entry)
                    }
                } header: {
                    HStack {
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
            }
        }
    }
}
