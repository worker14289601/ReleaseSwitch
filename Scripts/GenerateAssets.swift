import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawPNG(width: Int, height: Int, at url: URL, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
    ])
}
func appIcon(size: Int, at url: URL) throws {
    try drawPNG(width: size, height: size, at: url) {
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
        NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.19, blue: 0.37, alpha: 1),
                   ending: NSColor(srgbRed: 0.25, green: 0.44, blue: 0.81, alpha: 1))!.draw(in: plate, angle: 55)
        NSColor.white.withAlphaComponent(0.13).setStroke(); plate.lineWidth = 3; plate.stroke()
        let key = NSBezierPath(roundedRect: NSRect(x: 220, y: 332, width: 420, height: 370), xRadius: 62, yRadius: 62)
        NSColor(srgbRed: 0.79, green: 0.85, blue: 0.96, alpha: 1).setFill(); key.fill()
        let face = NSBezierPath(roundedRect: NSRect(x: 220, y: 356, width: 420, height: 346), xRadius: 62, yRadius: 62)
        NSColor.white.setFill(); face.fill()
        text("fn", x: 332, y: 422, size: 150, color: NSColor(srgbRed: 0.16, green: 0.29, blue: 0.52, alpha: 1), weight: .medium)
        for y in [350, 552] {
            let arrow = NSBezierPath(roundedRect: NSRect(x: 670, y: y, width: 140, height: 150), xRadius: 32, yRadius: 32)
            NSColor.white.withAlphaComponent(0.20).setFill(); arrow.fill()
        }
        text("↑", x: 708, y: 574, size: 74, color: .white, weight: .medium)
        text("↓", x: 708, y: 372, size: 74, color: .white, weight: .medium)
    }
}
for size in [16, 32, 128, 256, 512] {
    try appIcon(size: size, at: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try appIcon(size: size * 2, at: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try appIcon(size: 256, at: resources.appendingPathComponent("AppIcon.png"))
try drawPNG(width: 660, height: 420, at: resources.appendingPathComponent("DMGBackground.png")) {
    NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.985, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1))!
        .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 660, height: 420)), angle: 90)
    text("ReleaseSwitch", x: 40, y: 343, size: 30, color: NSColor(srgbRed: 0.12, green: 0.19, blue: 0.30, alpha: 1), weight: .semibold)
    text("Перетащи приложение в папку «Программы»", x: 42, y: 316, size: 14, color: .darkGray)
    text("→", x: 305, y: 161, size: 48, color: NSColor(srgbRed: 0.35, green: 0.46, blue: 0.63, alpha: 1))
    text("Apple Silicon · macOS 26+", x: 42, y: 285, size: 12, color: .darkGray, weight: .medium)
    text("Проверено на macOS 27. macOS 26: не проверено, возможны сбои.", x: 42, y: 264, size: 11, color: .darkGray)
}
print("Created app icon images and DMG background")
