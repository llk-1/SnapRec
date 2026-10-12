import AppKit
import Foundation

// An original vector drawing rasterized into the standard macOS AppIcon sizes.
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("SnapRec/Resources/Assets.xcassets")
let icon = output.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: CGRect(x: 65, y: 65, width: 894, height: 894), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.18, green: 0.25, blue: 0.40, alpha: 1), ending: NSColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1))!.draw(in: background, angle: -90)
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: CGRect(x: 240, y: 290, width: 544, height: 444), xRadius: 70, yRadius: 70)
        border.lineWidth = 34
        border.stroke()
        NSColor(red: 1, green: 0.25, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 385, y: 385, width: 254, height: 254)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: icon.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let info: [String: Any] = ["version": 1, "author": "xcode"]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: icon.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Generated original SnapRec AppIcon")
