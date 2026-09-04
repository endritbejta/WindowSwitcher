import AppKit
import CoreGraphics

/// One attached display, in the form the switcher needs it: an identity to
/// group windows by, a short number for the on-card badge, a human name for
/// the label, and the backing scale so previews are captured sharply.
struct DisplayRef: Equatable, Hashable {
    let id: CGDirectDisplayID
    /// 1-based, menu-bar display first — the compact hint shown on each card.
    let number: Int
    /// e.g. "Built-in Retina Display", "DELL U2720Q".
    let name: String
    /// Points-to-pixels factor (1 on a normal monitor, 2 on Retina).
    let scale: CGFloat
}

/// Everything the switcher needs to reason about a multi-display setup.
///
/// macOS hands us window geometry and screen geometry in two different
/// coordinate spaces, and confusing them is the classic way multi-monitor
/// support goes subtly wrong:
///
///   * **CoreGraphics** — `CGWindowListCopyWindowInfo`, `CGDisplayBounds` and
///     the Accessibility API use a top-left origin with y growing *downward*.
///   * **Cocoa** — `NSScreen`, `NSEvent.mouseLocation` and `NSWindow` use a
///     bottom-left origin with y growing *upward*.
///
/// Both are anchored to the menu-bar display, so a monitor placed above or
/// beside it gets very different numbers in each space: on a laptop with an
/// external screen sitting higher, that screen reports a CoreGraphics y of
/// -787 and an `NSScreen` y of 663. Any code that mixes the two, or assumes
/// coordinates are non-negative, puts windows on the wrong screen.
enum DisplayLayout {

    /// Every distinct display currently attached and awake.
    ///
    /// Mirrors are dropped. A mirrored pair occupies the same coordinates and
    /// shows the same windows, but only the display being mirrored has an
    /// `NSScreen`; leaving the copy in would let it win the overlap test for
    /// windows that then look like they're on no screen at all.
    static var distinctDisplayIDs: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// The current displays keyed by id, ready to stamp onto enumerated
    /// windows. Built once per enumeration rather than per window.
    static func currentDisplays() -> [CGDirectDisplayID: DisplayRef] {
        var result: [CGDirectDisplayID: DisplayRef] = [:]
        // `NSScreen.screens` puts the menu-bar display first, which makes it
        // display 1 — the numbering people expect from System Settings.
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let id = screen.displayID else { continue }
            result[id] = DisplayRef(
                id: id,
                number: index + 1,
                name: screen.localizedName,
                scale: screen.backingScaleFactor
            )
        }
        return result
    }

    /// The display showing most of `cgRect` (a window frame in CoreGraphics'
    /// top-left space).
    ///
    /// Largest overlap, not centre point: a window dragged across a bezel
    /// straddles two displays, and macOS itself considers it to live on
    /// whichever shows more of it. Picking by centre would also misfile a
    /// window whose middle falls in the gap between two screens of different
    /// heights that only partly line up.
    static func displayID(forCGRect cgRect: CGRect) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for id in distinctDisplayIDs {
            let overlap = CGDisplayBounds(id).intersection(cgRect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (id, area) }
        }
        return best?.id
    }

    /// The `NSScreen` backing a display id, for anything that has to talk in
    /// Cocoa coordinates (placing the overlay, reading the visible frame).
    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// The display carrying the menu bar — the origin of both coordinate
    /// spaces, and the sensible last resort when nothing better is known.
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }
}

extension NSScreen {

    /// The CoreGraphics display id for this screen, which is what window
    /// geometry and capture APIs speak in.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen the pointer is on.
    ///
    /// The pointer can legitimately be inside no screen frame at all — parked
    /// in the dead zone beside a shorter display in a mismatched arrangement,
    /// or mid-transit between two. Falling back to the menu-bar display there
    /// makes the overlay jump across the desk for no visible reason, so we
    /// fall back to the *nearest* screen instead.
    static var screenWithMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        if let hit = screens.first(where: { NSMouseInRect(location, $0.frame, false) }) {
            return hit
        }
        return screens.min { squaredDistance(from: location, to: $0.frame)
                           < squaredDistance(from: location, to: $1.frame) }
    }

    private static func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
