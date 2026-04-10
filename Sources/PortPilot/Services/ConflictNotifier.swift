import Foundation
import UserNotifications
import PortPilotCore

/// Thin wrapper around UNUserNotificationCenter.
/// All decision logic lives in `ConflictNotificationFilter` in PortPilotCore for testability.
///
/// UNUserNotificationCenter requires a valid app bundle (bundleIdentifier != nil).
/// When run via `swift run` the executable has no bundle, so notifications are disabled.
/// The app still functions — menu bar icon + UI conflict highlights work normally.
@MainActor
final class ConflictNotifier {
    private var filter = ConflictNotificationFilter()
    private let notificationsAvailable: Bool

    init() {
        // Check once at init — if no bundle identifier, notifications can't work.
        self.notificationsAvailable = Bundle.main.bundleIdentifier != nil
        if !notificationsAvailable {
            fputs("⚠️  ConflictNotifier: no bundle identifier — notifications disabled. Build via ./scripts/build-app.sh for full functionality.\n", stderr)
        }
    }

    func requestPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handleRefresh(diff: SnapshotDiff?, conflicts: [PortConflict]) {
        // Filter logic still runs (updates debounce state) — only dispatch is guarded.
        let toNotify = filter.portsToNotify(diff: diff, conflicts: conflicts)
        guard notificationsAvailable else { return }
        for conflict in toNotify {
            send(conflict)
        }
    }

    private func send(_ conflict: PortConflict) {
        let content = UNMutableNotificationContent()
        content.title = "Port Conflict"
        content.body = "Port \(conflict.port): \(conflict.conflictLabel)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "conflict-\(conflict.port)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
