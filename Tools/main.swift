import AppKit

// Renders the app icon into an .iconset directory, which `iconutil` then turns
// into the AppIcon.icns that Finder, the Dock and Spotlight read.
//
// This exists so the app icon and the menu-bar glyph cannot drift apart: both
// are drawn by `AppIcon` from the same 24x24 unit artwork. Nothing here is
// compiled into the app itself — build.sh builds it as a separate throwaway
// tool, runs it, and discards it.
//
// Usage: generate-app-icon <output.iconset directory>

/// The sizes an .icns is expected to carry: each logical size at 1x and 2x, so
/// macOS has an exact-pixel rendition for every place it draws the icon.
let logicalSizes = [16, 32, 128, 256, 512]

func renderPNG(pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        throw Failure("couldn't allocate a \(pixels)px bitmap")
    }
    rep.size = NSSize(width: pixels, height: pixels)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw Failure("couldn't make a drawing context for \(pixels)px")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    AppIcon.drawAppIcon(
        in: context.cgContext,
        rect: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("couldn't encode \(pixels)px as PNG")
    }
    try data.write(to: url)
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: generate-app-icon <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for size in logicalSizes {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            let name = "icon_\(size)x\(size)\(suffix).png"
            try renderPNG(pixels: size * scale, to: outputDirectory.appendingPathComponent(name))
        }
    }
} catch {
    FileHandle.standardError.write("icon generation failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
