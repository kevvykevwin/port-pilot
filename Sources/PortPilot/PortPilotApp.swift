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
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let sx = rect.width / 22
            let sy = rect.height / 22

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

            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true  // macOS auto-tints for light/dark mode
        return image
    }()

    /// Lighthouse with glowing amber beacon — used when multi-port projects detected
    static let menuBarImageActive: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let sx = rect.width / 22
            let sy = rect.height / 22

            // Draw the same lighthouse shape
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 11 * sx, y: 1.5 * sy))
            path.line(to: NSPoint(x: 8 * sx, y: 4.2 * sy))
            path.line(to: NSPoint(x: 14 * sx, y: 4.2 * sy))
            path.close()
            path.appendRect(NSRect(x: 8.9 * sx, y: 4.2 * sy, width: 4.2 * sx, height: 2.6 * sy))
            path.appendRect(NSRect(x: 8.0 * sx, y: 6.8 * sy, width: 6.0 * sx, height: 1.2 * sy))
            path.move(to: NSPoint(x: 14.0 * sx, y: 5.4 * sy))
            path.line(to: NSPoint(x: 20.5 * sx, y: 4.4 * sy))
            path.line(to: NSPoint(x: 20.5 * sx, y: 6.8 * sy))
            path.close()
            path.move(to: NSPoint(x: 8.7 * sx, y: 8.0 * sy))
            path.line(to: NSPoint(x: 9.9 * sx, y: 8.0 * sy))
            path.line(to: NSPoint(x: 9.2 * sx, y: 17.0 * sy))
            path.line(to: NSPoint(x: 8.0 * sx, y: 17.0 * sy))
            path.close()
            path.move(to: NSPoint(x: 12.1 * sx, y: 8.0 * sy))
            path.line(to: NSPoint(x: 13.3 * sx, y: 8.0 * sy))
            path.line(to: NSPoint(x: 14.0 * sx, y: 17.0 * sy))
            path.line(to: NSPoint(x: 12.8 * sx, y: 17.0 * sy))
            path.close()
            path.appendRect(NSRect(x: 10.4 * sx, y: 14.8 * sy, width: 1.2 * sx, height: 2.2 * sy))
            path.appendRect(NSRect(x: 7.0 * sx, y: 17.0 * sy, width: 8.0 * sx, height: 1.6 * sy))

            NSColor.black.setFill()
            path.fill()

            // Amber glow beam — same triangle shape as the light beam
            let glowBeam = NSBezierPath()
            glowBeam.move(to: NSPoint(x: 14.0 * sx, y: 5.4 * sy))
            glowBeam.line(to: NSPoint(x: 20.5 * sx, y: 4.4 * sy))
            glowBeam.line(to: NSPoint(x: 20.5 * sx, y: 6.8 * sy))
            glowBeam.close()
            NSColor.orange.setFill()
            glowBeam.fill()

            return true
        }
        // NOT template — we want the amber dot to keep its color
        image.isTemplate = false
        return image
    }()
}
