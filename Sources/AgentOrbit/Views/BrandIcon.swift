import AppKit
import SwiftUI

enum BrandIconFactory {
    @MainActor
    static func menuBarImage(isLive: Bool, needsInput: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let center = NSPoint(x: rect.midX, y: rect.midY)

            // Outer precision ring (open coordinate arc)
            let ring = NSBezierPath()
            ring.lineWidth = 1.5
            ring.lineCapStyle = .round
            ring.appendArc(withCenter: center, radius: 6.4, startAngle: 25, endAngle: 205)
            ring.stroke()

            let lowerRing = NSBezierPath()
            lowerRing.lineWidth = 1.5
            lowerRing.lineCapStyle = .round
            lowerRing.appendArc(withCenter: center, radius: 6.4, startAngle: 225, endAngle: 355)
            lowerRing.stroke()

            // Center project core
            let coreRect = NSRect(x: center.x - 2.3, y: center.y - 2.3, width: 4.6, height: 4.6)
            NSBezierPath(ovalIn: coreRect).fill()

            // Twin agent satellite nodes (Codex & Antigravity)
            let nodeA = NSRect(x: center.x + 3.6, y: center.y + 3.6, width: 2.8, height: 2.8)
            NSBezierPath(ovalIn: nodeA).fill()

            let nodeB = NSRect(x: center.x - 6.4, y: center.y - 6.0, width: 2.6, height: 2.6)
            NSBezierPath(ovalIn: nodeB).fill()

            if isLive || needsInput {
                // Small active/waiting pulse ring around core
                let pulse = NSBezierPath()
                pulse.lineWidth = needsInput ? 1.3 : 1.0
                pulse.appendArc(withCenter: center, radius: 4.1, startAngle: 0, endAngle: 360)
                pulse.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}

struct BrandBadgeView: View {
    var size: CGFloat = 24
    var isLive: Bool = false
    var needsInput: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.14, blue: 0.22),
                            Color(red: 0.18, green: 0.25, blue: 0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                )

            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let r = min(canvasSize.width, canvasSize.height) * 0.33

                var arc1 = Path()
                arc1.addArc(center: center, radius: r, startAngle: .degrees(-155), endAngle: .degrees(15), clockwise: false)
                context.stroke(arc1, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                var arc2 = Path()
                arc2.addArc(center: center, radius: r, startAngle: .degrees(35), endAngle: .degrees(175), clockwise: false)
                context.stroke(arc2, with: .color(.cyan.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                let coreSize = size * 0.20
                let coreRect = CGRect(
                    x: center.x - coreSize / 2,
                    y: center.y - coreSize / 2,
                    width: coreSize,
                    height: coreSize
                )
                context.fill(
                    Path(ellipseIn: coreRect),
                    with: .color(needsInput ? .orange : (isLive ? .green : .white))
                )

                let satSize = size * 0.12
                let sat1 = CGRect(x: center.x + r * 0.55, y: center.y - r * 0.85, width: satSize, height: satSize)
                let sat2 = CGRect(x: center.x - r * 0.85, y: center.y + r * 0.55, width: satSize, height: satSize)
                context.fill(Path(ellipseIn: sat1), with: .color(.cyan))
                context.fill(Path(ellipseIn: sat2), with: .color(.orange))
            }
        }
        .frame(width: size, height: size)
    }
}
