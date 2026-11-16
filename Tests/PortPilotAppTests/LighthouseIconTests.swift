import AppKit
import SwiftUI
import XCTest
@testable import PortPilot

/// Renders the menu bar lighthouse and reads the pixels back, so these tests
/// check what the menu bar actually shows rather than which image was picked.
@MainActor
final class LighthouseIconTests: XCTestCase {
    private struct RGB: Equatable, CustomStringConvertible {
        let red: CGFloat, green: CGFloat, blue: CGFloat
        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)
        static let red = RGB(red: 1, green: 0, blue: 0)
        static let orange = RGB(red: 1, green: 0.5, blue: 0)
        var description: String { "(\(red), \(green), \(blue))" }
    }

    /// Interior opaque pixels, split into tower (left of the beam) and beam tip.
    private struct Pixels {
        let tower: [RGB]
        let beam: [RGB]
    }

    // MARK: - Rendering helpers

    private func makeBitmap(side: Int) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
    }

    /// Draws `image` directly under `appearance`. Passing the opposite of the
    /// appearance an image was picked for proves its colors are baked in and
    /// don't depend on the drawing appearance.
    private func render(_ image: NSImage, under appearance: NSAppearance.Name) throws -> Pixels {
        let side = 88
        let rep = try makeBitmap(side: side)
        let drawingAppearance = try XCTUnwrap(NSAppearance(named: appearance))
        drawingAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
        }
        return pixels(in: rep, iconRect: CGRect(x: 0, y: 0, width: side, height: side), interiorOnly: true)
    }

    /// Renders the real SwiftUI label after setting its window's appearance.
    /// This goes through SwiftUI's image cache, which is where a single image
    /// that picks its color while drawing goes stale.
    private func renderLabel(
        _ state: LighthouseIcon.State, in window: NSWindow, appearance: NSAppearance.Name,
        minAlpha: CGFloat = 0.99
    ) throws -> Pixels {
        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<MenuBarIconLabel>)
        window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
        // In the app only the environment changes on an appearance flip, so
        // don't rebuild the root view unless the state really differs.
        if hostingView.rootView.state != state {
            hostingView.rootView = MenuBarIconLabel(state: state)
        }
        // SwiftUI applies the new appearance synchronously during layout.
        hostingView.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        // The label sizes itself to the 18 pt image; center it in the bitmap.
        let scale = CGFloat(rep.pixelsWide) / hostingView.bounds.width
        let icon = 18 * scale
        let iconRect = CGRect(
            x: (CGFloat(rep.pixelsWide) - icon) / 2, y: (CGFloat(rep.pixelsHigh) - icon) / 2,
            width: icon, height: icon
        )
        // At menu bar size few pixels are interior; edge pixels are excluded
        // by the full-opacity check instead.
        return pixels(in: rep, iconRect: iconRect, interiorOnly: false, minAlpha: minAlpha)
    }

    /// An offscreen window hosting the label at menu bar size.
    private func makeLabelWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 18, height: 18),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuBarIconLabel(state: .active))
        window.orderBack(nil)
        addTeardownBlock { window.close() }
        return window
    }

    /// The tower spans x 7…15 and the beam x 14…20.5 in the icon's 22-unit grid,
    /// so grid x < 13 is tower-only and grid x > 16 is beam-only.
    /// Only interior pixels count: anti-aliased edges blend the beam into the
    /// tower beneath it, so their color is a mix, not the color under test.
    private func pixels(
        in rep: NSBitmapImageRep, iconRect: CGRect, interiorOnly: Bool, minAlpha: CGFloat = 0.99
    ) -> Pixels {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        func color(_ x: Int, _ y: Int) -> NSColor? {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
            return rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        }
        func isOpaque(_ x: Int, _ y: Int) -> Bool { (color(x, y)?.alphaComponent ?? 0) > minAlpha }

        var tower: [RGB] = []
        var beam: [RGB] = []
        for y in 0..<height {
            for x in 0..<width {
                let counted = interiorOnly
                    ? (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in isOpaque(x + dx, y + dy) } }
                    : isOpaque(x, y)
                guard counted, let c = color(x, y) else { continue }
                let rgb = RGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
                let gridX = (Double(x) - iconRect.minX) / iconRect.width * 22
                if gridX < 13 { tower.append(rgb) }
                if gridX > 16 { beam.append(rgb) }
            }
        }
        return Pixels(tower: tower, beam: beam)
    }

    private func assertAll(
        _ colors: [RGB], are expected: RGB, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(colors.isEmpty, "\(message): no opaque pixels rendered", file: file, line: line)
        if let wrong = colors.first(where: {
            abs($0.red - expected.red) > 0.1 || abs($0.green - expected.green) > 0.1 || abs($0.blue - expected.blue) > 0.1
        }) {
            XCTFail("\(message): expected \(expected), got \(wrong)", file: file, line: line)
        }
    }

    /// The label's window renders through the display's color space, so a
    /// saturated beam comes back shifted (pure red reads about (0.94, 0.30, 0.19)
    /// in device RGB). White and black survive exactly; for the beam, check that
    /// most pixels are clearly red and not orange (orange keeps green near 0.5+).
    private func assertMostlyRed(
        _ colors: [RGB], _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let red = colors.filter { $0.red > 0.8 && $0.green < 0.4 && $0.blue < 0.4 }
        XCTAssertGreaterThan(
            Double(red.count), Double(colors.count) * 0.6,
            "\(message): \(red.count) of \(colors.count) pixels are red: \(colors)", file: file, line: line
        )
    }

    // MARK: - Tower contrasts with the menu bar

    /// Catches the original bug: a beam icon drew a black tower on a dark menu bar.
    func test_beamIcons_drawWhiteTower_forDarkMenuBar() throws {
        for state in [LighthouseIcon.State.active, .conflict] {
            // Drawn under the *light* appearance: the white must be baked in.
            let pixels = try render(LighthouseIcon.image(for: state, darkMenuBar: true), under: .aqua)
            assertAll(pixels.tower, are: .white, "\(state) tower for dark menu bar")
        }
    }

    /// Catches a fix that hardcodes white, which would vanish on a light menu bar.
    func test_beamIcons_drawBlackTower_forLightMenuBar() throws {
        for state in [LighthouseIcon.State.active, .conflict] {
            let pixels = try render(LighthouseIcon.image(for: state, darkMenuBar: false), under: .darkAqua)
            assertAll(pixels.tower, are: .black, "\(state) tower for light menu bar")
        }
    }

    // MARK: - Beacon keeps its color

    /// Catches the beam being painted in the tower color or dropped.
    func test_beamColor_isOrangeWhenActive_andRedOnConflict_onBothMenuBars() throws {
        for dark in [false, true] {
            let active = try render(LighthouseIcon.image(for: .active, darkMenuBar: dark), under: .aqua)
            assertAll(active.beam, are: .orange, "active beam (dark menu bar: \(dark))")
            let conflict = try render(LighthouseIcon.image(for: .conflict, darkMenuBar: dark), under: .aqua)
            assertAll(conflict.beam, are: .red, "conflict beam (dark menu bar: \(dark))")
        }
    }

    // MARK: - The SwiftUI label follows appearance changes

    /// Catches the stale-icon bug: SwiftUI rasterizes `Image(nsImage:)` once, so
    /// a single image that picks its color while drawing keeps the first color.
    /// The same hosting view must change tower color when its appearance flips.
    func test_label_switchesTowerColor_whenMenuBarAppearanceFlips() throws {
        let window = makeLabelWindow()
        let sequence: [(NSAppearance.Name, RGB)] = [
            (.darkAqua, .white), (.aqua, .black), (.darkAqua, .white), (.aqua, .black),
        ]
        for (appearance, expected) in sequence {
            let pixels = try renderLabel(.active, in: window, appearance: appearance)
            assertAll(pixels.tower, are: expected, "label tower under \(appearance.rawValue)")
        }
    }

    /// Catches the label ignoring state changes (e.g. always drawing idle).
    func test_label_showsRedBeam_forConflict_onDarkMenuBar() throws {
        let pixels = try renderLabel(.conflict, in: makeLabelWindow(), appearance: .darkAqua)
        assertAll(pixels.tower, are: .white, "conflict label tower")
        assertMostlyRed(pixels.beam, "conflict label beam")
    }

    /// Catches idle losing AppKit/SwiftUI template tinting in the label: it
    /// would draw its black mask as-is on a dark menu bar. Template tinting
    /// uses the semi-transparent label color, so partly opaque pixels count.
    func test_label_tintsIdleTowerLight_onDarkMenuBar() throws {
        let pixels = try renderLabel(.idle, in: makeLabelWindow(), appearance: .darkAqua, minAlpha: 0.5)
        XCTAssertFalse(pixels.tower.isEmpty, "idle label drew nothing")
        let dark = pixels.tower.filter { $0.red < 0.5 && $0.green < 0.5 && $0.blue < 0.5 }
        XCTAssertTrue(dark.isEmpty, "idle tower has \(dark.count) dark pixels on a dark menu bar")
    }

    // MARK: - Template flags

    /// Catches the beam variants becoming templates (AppKit would tint the beam
    /// to the menu bar color and hide the beacon), or idle losing template
    /// tinting (it would draw black on a dark menu bar).
    func test_onlyIdleIcon_isTemplate() {
        for dark in [false, true] {
            XCTAssertTrue(LighthouseIcon.image(for: .idle, darkMenuBar: dark).isTemplate)
            XCTAssertFalse(LighthouseIcon.image(for: .active, darkMenuBar: dark).isTemplate)
            XCTAssertFalse(LighthouseIcon.image(for: .conflict, darkMenuBar: dark).isTemplate)
        }
    }
}
