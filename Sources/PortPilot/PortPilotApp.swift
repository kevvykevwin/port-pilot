import SwiftUI
import PortPilotCore

@main
struct PortPilotApp: App {
    @State private var store = PortStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Label("\(store.listeningCount)", systemImage: "network")
        }
        .menuBarExtraStyle(.window)
    }
}
