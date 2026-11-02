import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Assets.xcassets")
let manager = FileManager.default
try manager.createDirectory(at: root, withIntermediateDirectories: true)
func save(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
try save(["info": ["author": "xcode", "version": 1]], root.appendingPathComponent("Contents.json"))
let colors: [String: (String, String)] = [
    "Canvas": ("F9F8F5", "1D1C20"), "Panel": ("FFFFFF", "28262D"),
    "Ink": ("28252F", "F1EDF7"), "Secondary": ("797480", "AAA4B2"),
    "Accent": ("65518A", "9B82C6"), "Line": ("E9E5ED", "39343F")
]
for (name, pair) in colors {
    let folder = root.appendingPathComponent(name + ".colorset")
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    var entries: [[String: Any]] = []
    for (index, hex) in [pair.0, pair.1].enumerated() {
        let number = UInt32(hex, radix: 16)!
        var entry: [String: Any] = ["idiom": "universal", "color": ["color-space": "srgb", "components": [
            "red": String(format: "0x%02X", (number >> 16) & 255),
            "green": String(format: "0x%02X", (number >> 8) & 255),
            "blue": String(format: "0x%02X", number & 255), "alpha": "1.000"]]]
        if index == 1 { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
        entries.append(entry)
    }
    try save(["colors": entries, "info": ["author": "xcode", "version": 1]], folder.appendingPathComponent("Contents.json"))
}
let icon = root.appendingPathComponent("AppIcon.appiconset")
try manager.createDirectory(at: icon, withIntermediateDirectories: true)
var icons: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 195, yRadius: 195)
        NSGradient(colors: [NSColor(srgbRed: 0.96, green: 0.94, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.80, green: 0.77, blue: 0.91, alpha: 1)])!.draw(in: tile, angle: -50)
        let sphere = NSBezierPath(ovalIn: NSRect(x: 208, y: 208, width: 608, height: 608))
        NSGradient(colors: [NSColor(srgbRed: 0.68, green: 0.81, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.56, green: 0.39, blue: 0.78, alpha: 1), NSColor(srgbRed: 0.33, green: 0.24, blue: 0.57, alpha: 1)])!.draw(in: sphere, angle: -45)
        NSColor.white.withAlphaComponent(0.9).setFill()
        for index in 0..<17 {
            let progress = Double(index) / 16
            let height = 25 + pow(sin(progress * .pi), 1.2) * (90 + 65 * abs(sin(progress * 13)))
            NSBezierPath(roundedRect: NSRect(x: 310 + Double(index) * 25, y: 512 - height / 2, width: 10, height: height), xRadius: 5, yRadius: 5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)_\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: icon.appendingPathComponent(filename))
        icons.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try save(["images": icons, "info": ["author": "xcode", "version": 1]], icon.appendingPathComponent("Contents.json"))
