import SwiftUI
import AppKit
import PortPilotCore

@main
struct PortPilotApp: App {
    @State private var store = PortStore(defaults: .standard, serveReader: TailscaleServeReader())
    private let notifier = ConflictNotifier()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            MenuBarIconLabel(state: store.hasConflicts
                ? .conflict
                : store.hasMultiPortProjects ? .active : .idle)
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        notifier.requestPermission()
        // notifier outlives store; strong capture is intentional
        let capturedNotifier = notifier
        store.onRefreshComplete = { diff, conflicts in
            capturedNotifier.handleRefresh(diff: diff, conflicts: conflicts)
        }
        // Start polling immediately so the lighthouse icon reflects
        // state without needing to open the popover.
        store.startPolling()
    }
}

/// Picks the lighthouse image for the menu bar's current light/dark appearance.
///
/// SwiftUI rasterizes an `Image(nsImage:)` once and keeps the bitmap, even when
/// the image has a drawing handler, so one image cannot follow appearance
/// changes by itself. `colorScheme` in a `MenuBarExtra` label follows the main
/// menu bar's appearance, so the label swaps images instead. With several
/// displays tinted differently, the beam icons follow the main one; only the
/// template idle icon is tinted per screen.
struct MenuBarIconLabel: View {
    let state: LighthouseIcon.State
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: LighthouseIcon.image(for: state, darkMenuBar: colorScheme == .dark))
    }
}

/// Menu bar lighthouse icons, drawn with `NSBezierPath` (Canvas and SF Symbols
/// don't render in `MenuBarExtra` labels).
enum LighthouseIcon {
    enum State: CaseIterable, Sendable {
        /// No beam. Template image: AppKit tints it for light and dark menu bars.
        case idle
        /// Amber beam — multi-port projects detected.
        case active
        /// Red beam — true port conflicts detected.
        case conflict
    }

    /// The image to show for `state` on a light or dark menu bar.
    ///
    /// The beam variants can't be templates (AppKit would tint the beam too),
    /// so their tower color is baked in per appearance: black on a light menu
    /// bar, white on a dark one.
    static func image(for state: State, darkMenuBar: Bool) -> NSImage {
        switch (state, darkMenuBar) {
        case (.idle, _): idleImage
        case (.active, false): activeLight
        case (.active, true): activeDark
        case (.conflict, false): conflictLight
        case (.conflict, true): conflictDark
        }
    }

    private static let idleImage = makeImage(tower: .black, beam: nil)
    private static let activeLight = makeImage(tower: .black, beam: .orange)
    private static let activeDark = makeImage(tower: .white, beam: .orange)
    private static let conflictLight = makeImage(tower: .black, beam: .red)
    private static let conflictDark = makeImage(tower: .white, beam: .red)

    /// Builds the lighthouse path into `path` using the scaled coordinate space.
    private static func buildLighthousePath(sx: CGFloat, sy: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        // Roof triangle
        path.move(to: NSPoint(x: 11 * sx, y: 1.5 * sy))
        path.line(to: NSPoint(x: 8 * sx, y: 4.2 * sy))
        path.line(to: NSPoint(x: 14 * sx, y: 4.2 * sy))
        path.close()
        // Lantern room
        path.appendRect(NSRect(x: 8.9 * sx, y: 4.2 * sy, width: 4.2 * sx, height: 2.6 * sy))
        // Catwalk
        path.appendRect(NSRect(x: 8.0 * sx, y: 6.8 * sy, width: 6.0 * sx, height: 1.2 * sy))
        // Light beam
        path.move(to: NSPoint(x: 14.0 * sx, y: 5.4 * sy))
        path.line(to: NSPoint(x: 20.5 * sx, y: 4.4 * sy))
        path.line(to: NSPoint(x: 20.5 * sx, y: 6.8 * sy))
        path.close()
        // Left tower leg
        path.move(to: NSPoint(x: 8.7 * sx, y: 8.0 * sy))
        path.line(to: NSPoint(x: 9.9 * sx, y: 8.0 * sy))
        path.line(to: NSPoint(x: 9.2 * sx, y: 17.0 * sy))
        path.line(to: NSPoint(x: 8.0 * sx, y: 17.0 * sy))
        path.close()
        // Right tower leg
        path.move(to: NSPoint(x: 12.1 * sx, y: 8.0 * sy))
        path.line(to: NSPoint(x: 13.3 * sx, y: 8.0 * sy))
        path.line(to: NSPoint(x: 14.0 * sx, y: 17.0 * sy))
        path.line(to: NSPoint(x: 12.8 * sx, y: 17.0 * sy))
        path.close()
        // Door
        path.appendRect(NSRect(x: 10.4 * sx, y: 14.8 * sy, width: 1.2 * sx, height: 2.2 * sy))
        // Base
        path.appendRect(NSRect(x: 7.0 * sx, y: 17.0 * sy, width: 8.0 * sx, height: 1.6 * sy))
        return path
    }

    /// Draws the lighthouse with a fixed tower color and an optional colored beam.
    /// Beam-less images are templates; images with a beam are not.
    private static func makeImage(tower: NSColor, beam beamColor: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let sx = rect.width / 22
            let sy = rect.height / 22
            let path = buildLighthousePath(sx: sx, sy: sy)
            tower.setFill()
            path.fill()
            if let beamColor {
                // Glow beam — same triangle as the light beam, painted on top
                let beam = NSBezierPath()
                beam.move(to: NSPoint(x: 14.0 * sx, y: 5.4 * sy))
                beam.line(to: NSPoint(x: 20.5 * sx, y: 4.4 * sy))
                beam.line(to: NSPoint(x: 20.5 * sx, y: 6.8 * sy))
                beam.close()
                beamColor.setFill()
                beam.fill()
            }
            return true
        }
        image.isTemplate = beamColor == nil
        return image
    }
}
