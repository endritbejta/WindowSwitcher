import AppKit

/// The Window Switcher menu-bar logo.
///
/// Design: a rounded "squircle" tile — standing in for a window — filled
/// with a solid purple gradient (a slight fade, not a wide sweep), with two
/// separate white arcs drawn on top rather than one closed ring (each with
/// its own arrowhead) — reads as two things swapping places, not a single
/// refresh loop.
enum AppIcon {

    /// Builds the status-item image. Resolution independent — draws fresh
    /// at whatever backing scale the menu bar requests (1x/2x/3x), so it
    /// stays crisp on every display.
    static func makeStatusItemImage(size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect)
            return true
        }
        // Full color, not a monochrome menu-bar template — the gradient is
        // the point.
        image.isTemplate = false
        image.accessibilityDescription = "Window Switcher"
        return image
    }

    /// Draws the logo into `rect` of `ctx`. Authored on a 24x24 unit grid
    /// and scaled to fit, so it can be rendered at any size.
    static func draw(in ctx: CGContext, rect: CGRect) {
        let scale = rect.width / 24.0

        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: scale, y: scale)

        // 1) Squircle badge: the two solid, saturated purples with a slight
        // fade between them, rather than a wide light-to-dark sweep.
        let badgeRect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.addPath(badgePath)
        ctx.clip()

        let colors = [
            NSColor(calibratedRed: 0.184, green: 0.094, blue: 0.294, alpha: 1).cgColor, // #2F184B deep purple
            NSColor(calibratedRed: 0.325, green: 0.169, blue: 0.533, alpha: 1).cgColor, // #532B88 purple
        ]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: colors as CFArray,
                                   locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                                start: CGPoint(x: 0, y: 24),
                                end: CGPoint(x: 24, y: 0),
                                options: [])
        ctx.resetClip()

        // 2) Refresh / switch glyph: two DISTINCT rounded arcs (a visible
        // gap between them, not a closed ring) each in its own color, each
        // ending in a soft rounded arrowhead — reads as two things swapping
        // places rather than one continuous refresh loop.
        let lineWidth: CGFloat = 2.15
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(lineWidth)

        let center = CGPoint(x: 12, y: 12)
        let radius: CGFloat = 6.0
        func degToRad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

        // Each arc sweeps 122°, leaving a wider ~58° gap on either side
        // between one arc's arrowhead and the other arc's plain tail end.
        // Both arrows plain white, for clean contrast against the solid
        // purple badge.
        let arc1Color = NSColor.white.cgColor
        let arc2Color = NSColor.white.cgColor

        ctx.setStrokeColor(arc1Color)
        ctx.addArc(center: center, radius: radius,
                   startAngle: degToRad(151), endAngle: degToRad(29), clockwise: true)
        ctx.strokePath()

        ctx.setStrokeColor(arc2Color)
        ctx.addArc(center: center, radius: radius,
                   startAngle: degToRad(-29), endAngle: degToRad(-151), clockwise: true)
        ctx.strokePath()

        // Rounded arrowhead at the leading end of each arc: a small
        // triangle whose base sits along the radius (perpendicular to the
        // direction of travel) and whose tip pokes a little further along
        // the arc — filled, then re-stroked with a round join so the sharp
        // corners come out soft instead of pointed.
        func arrowhead(at angleDeg: CGFloat, clockwise: Bool, color: CGColor) {
            let a = degToRad(angleDeg)
            let radialDir = CGPoint(x: cos(a), y: sin(a))
            let end = CGPoint(x: center.x + radius * radialDir.x, y: center.y + radius * radialDir.y)
            let tangentDir = clockwise ? CGPoint(x: radialDir.y, y: -radialDir.x)
                                        : CGPoint(x: -radialDir.y, y: radialDir.x)

            let tipExtend: CGFloat = 2.3
            let baseInset: CGFloat = 0.3
            let halfWidth: CGFloat = 1.45

            let tip = CGPoint(x: end.x + tangentDir.x * tipExtend, y: end.y + tangentDir.y * tipExtend)
            let baseCenter = CGPoint(x: end.x - tangentDir.x * baseInset, y: end.y - tangentDir.y * baseInset)
            let corner1 = CGPoint(x: baseCenter.x + radialDir.x * halfWidth, y: baseCenter.y + radialDir.y * halfWidth)
            let corner2 = CGPoint(x: baseCenter.x - radialDir.x * halfWidth, y: baseCenter.y - radialDir.y * halfWidth)

            let path = CGMutablePath()
            path.move(to: corner1)
            path.addLine(to: tip)
            path.addLine(to: corner2)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(1.5)
            ctx.drawPath(using: .fillStroke) // stroke rounds the fill's sharp corners
        }

        arrowhead(at: 29, clockwise: true, color: arc1Color)
        arrowhead(at: -151, clockwise: true, color: arc2Color)

        ctx.restoreGState()
    }
}
