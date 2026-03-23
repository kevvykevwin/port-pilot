import SwiftUI
import PortPilotCore

@main
struct PortPilotApp: App {
    @State private var store = PortStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            HStack(spacing: 4) {
                LighthouseIcon()
                    .frame(width: 16, height: 16)
                Text("\(store.listeningCount)")
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Lighthouse icon drawn in SwiftUI — matches the SVG design
struct LighthouseIcon: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 22
            let sy = size.height / 22

            // Roof triangle
            let roof = Path { p in
                p.move(to: CGPoint(x: 11 * sx, y: 1.5 * sy))
                p.addLine(to: CGPoint(x: 8 * sx, y: 4.2 * sy))
                p.addLine(to: CGPoint(x: 14 * sx, y: 4.2 * sy))
                p.closeSubpath()
            }
            context.fill(roof, with: .foreground)

            // Lantern room
            context.fill(Path(CGRect(x: 8.9 * sx, y: 4.2 * sy, width: 4.2 * sx, height: 2.6 * sy)), with: .foreground)

            // Catwalk
            context.fill(Path(CGRect(x: 8.0 * sx, y: 6.8 * sy, width: 6.0 * sx, height: 1.2 * sy)), with: .foreground)

            // Light beam
            let beam = Path { p in
                p.move(to: CGPoint(x: 14.0 * sx, y: 5.4 * sy))
                p.addLine(to: CGPoint(x: 20.5 * sx, y: 4.4 * sy))
                p.addLine(to: CGPoint(x: 20.5 * sx, y: 6.8 * sy))
                p.closeSubpath()
            }
            context.fill(beam, with: .foreground)

            // Tower legs (tapered)
            let leftLeg = Path { p in
                p.move(to: CGPoint(x: 8.7 * sx, y: 8.0 * sy))
                p.addLine(to: CGPoint(x: 9.9 * sx, y: 8.0 * sy))
                p.addLine(to: CGPoint(x: 9.2 * sx, y: 17.0 * sy))
                p.addLine(to: CGPoint(x: 8.0 * sx, y: 17.0 * sy))
                p.closeSubpath()
            }
            context.fill(leftLeg, with: .foreground)

            let rightLeg = Path { p in
                p.move(to: CGPoint(x: 12.1 * sx, y: 8.0 * sy))
                p.addLine(to: CGPoint(x: 13.3 * sx, y: 8.0 * sy))
                p.addLine(to: CGPoint(x: 14.0 * sx, y: 17.0 * sy))
                p.addLine(to: CGPoint(x: 12.8 * sx, y: 17.0 * sy))
                p.closeSubpath()
            }
            context.fill(rightLeg, with: .foreground)

            // Door
            context.fill(Path(CGRect(x: 10.4 * sx, y: 14.8 * sy, width: 1.2 * sx, height: 2.2 * sy)), with: .foreground)

            // Base
            context.fill(Path(CGRect(x: 7.0 * sx, y: 17.0 * sy, width: 8.0 * sx, height: 1.6 * sy)), with: .foreground)
        }
    }
}
