import SwiftUI
import AppKit
import PortPilotCore

@main
struct PortPilotApp: App {
    @State private var store = PortStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(nsImage: store.hasMultiPortProjects
                ? LighthouseIcon.menuBarImageActive
                : LighthouseIcon.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Generates an NSImage template for the menu bar lighthouse icon
enum LighthouseIcon {
    static let menuBarImage: NSImage = makeImage(active: false)
    /// Lighthouse with glowing amber beacon — used when multi-port projects detected
    static let menuBarImageActive: NSImage = makeImage(active: true)

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

    private static func makeImage(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let sx = rect.width / 22
            let sy = rect.height / 22
            let path = buildLighthousePath(sx: sx, sy: sy)
            NSColor.black.setFill()
            path.fill()
            if active {
                // Amber glow beam — same triangle as the light beam, painted on top
                let beam = NSBezierPath()
                beam.move(to: NSPoint(x: 14.0 * sx, y: 5.4 * sy))
                beam.line(to: NSPoint(x: 20.5 * sx, y: 4.4 * sy))
                beam.line(to: NSPoint(x: 20.5 * sx, y: 6.8 * sy))
                beam.close()
                NSColor.orange.setFill()
                beam.fill()
            }
            return true
        }
        // Template images are auto-tinted for light/dark mode.
        // Active variant must NOT be a template — the amber beam must keep its color.
        image.isTemplate = !active
        return image
    }
}
