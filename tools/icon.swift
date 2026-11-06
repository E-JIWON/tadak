// Draws Tadak's app icon (a keycap marked 탁 on a teal tile) and writes AppIcon.icns: swift tools/icon.swift
import AppKit

func draw(_ n: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(n) / 1024  // drawn on the 1024 grid, where macOS icons are an 824 tile with radius 185
    let rgb = { (r: Int, g: Int, b: Int) in NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u), xRadius: 185 * u, yRadius: 185 * u)
    NSGradient(starting: rgb(45, 212, 191), ending: rgb(15, 118, 110))!.draw(in: tile, angle: -90)
    // Keycap: a shadowed skirt, then the dished top a little up and in from it.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width: 0, height: -18 * u)
    shadow.shadowBlurRadius = 36 * u
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    let skirt = NSBezierPath(roundedRect: NSRect(x: 262 * u, y: 250 * u, width: 500 * u, height: 500 * u), xRadius: 96 * u, yRadius: 96 * u)
    rgb(203, 213, 225).setFill(); skirt.fill()
    NSGraphicsContext.restoreGraphicsState()
    let top = NSBezierPath(roundedRect: NSRect(x: 312 * u, y: 330 * u, width: 400 * u, height: 380 * u), xRadius: 70 * u, yRadius: 70 * u)
    NSGradient(starting: rgb(255, 255, 255), ending: rgb(226, 232, 240))!.draw(in: top, angle: -90)
    let font = NSFont.systemFont(ofSize: 210 * u, weight: .heavy)
    let label = NSAttributedString(string: "탁", attributes: [.font: font, .foregroundColor: rgb(15, 118, 110)])
    let size = label.size()
    label.draw(at: NSPoint(x: 512 * u - size.width / 2, y: 520 * u - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! draw(pt * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed")
