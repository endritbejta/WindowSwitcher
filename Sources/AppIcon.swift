import AppKit

/// The Window Switcher logo, used both for the menu-bar item and for the app
/// icon that Finder, the Dock and Spotlight show.
///
/// Design: a rounded "squircle" tile — standing in for a window — filled
/// with a solid purple gradient (a slight fade, not a wide sweep), with two
/// separate white arcs drawn on top rather than one closed ring (each with
/// its own arrowhead) — reads as two things swapping places, not a single
/// refresh loop.
///
/// The artwork is authored once on a 24x24 unit grid and rendered at whatever
/// size is asked for. The two entry points differ only in framing: the menu-bar
/// glyph fills its rect edge to edge, while the app icon insets the tile and
/// uses Apple's corner radius so it sits correctly beside other app icons.
enum AppIcon {

    /// The logo's purple, lifted for use as a UI tint.
    ///
    /// The icon's own gradient runs dark (#2F184B to #532B88) because it is
    /// read as a filled tile at small sizes. A tint painted *onto* a window
    /// preview has to hold its own against both a white document and a dark
    /// editor, so this is the same hue a few steps brighter rather than either
    /// of the gradient's colours.
    static let brandTint = NSColor(calibratedRed: 0.502, green: 0.310, blue: 0.800, alpha: 1) // #804FCC

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

    /// Proportion of an app-icon canvas the tile itself occupies. macOS app
    /// icons are drawn inset rather than edge to edge (Apple's own grid puts the
    /// 1024pt canvas's artwork at 824pt), so an edge-to-edge tile would look
    /// oversized next to every other icon in the Dock and in Spotlight.
    private static let appIconArtworkFraction: CGFloat = 824.0 / 1024.0

    /// Corner radius of the tile as a fraction of its width. Edge-to-edge in the
    /// menu bar the logo reads better slightly rounder; as an app icon it should
    /// match the system's radius.
    private static let menuBarCornerFraction: CGFloat = 7.0 / 24.0
    private static let appIconCornerFraction: CGFloat = 0.2237

    /// Draws the logo into `rect` of `ctx`, filling it edge to edge. Authored on
    /// a 24x24 unit grid and scaled to fit, so it can be rendered at any size.
    static func draw(in ctx: CGContext, rect: CGRect) {
        drawArtwork(in: ctx, rect: rect, cornerFraction: menuBarCornerFraction)
    }

    /// Draws the app-icon rendering into `rect`: the same tile, inset within the
    /// canvas and with the system corner radius.
    static func drawAppIcon(in ctx: CGContext, rect: CGRect) {
        let side = min(rect.width, rect.height) * appIconArtworkFraction
        let artwork = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        drawArtwork(in: ctx, rect: artwork, cornerFraction: appIconCornerFraction)
    }

    private static func drawArtwork(in ctx: CGContext, rect: CGRect, cornerFraction: CGFloat) {
        let scale = rect.width / 24.0
        let corner = 24.0 * cornerFraction

        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: scale, y: scale)

        // 1) Squircle badge: the two solid, saturated purples with a slight
        // fade between them, rather than a wide light-to-dark sweep.
        let badgeRect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
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
