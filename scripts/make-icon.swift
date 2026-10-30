// Generates Resources/AppIcon.icns: swift scripts/make-icon.swift
// Two usage bars with time ticks: one account with room left, one nearly used up.
// Pass a directory as the first argument to also keep the PNGs for inspection.
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func capsule(_ c: CGContext, _ rect: CGRect, _ color: CGColor) {
    let radius = min(rect.width, rect.height) / 2
    c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.setFillColor(color)
    c.fillPath()
}

/// Draws on a 1024-point canvas, using the macOS icon grid: an 824-point body with a soft shadow.
func drawIcon(_ c: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.32))
    c.addPath(shape)
    c.setFillColor(rgb(0x34445E))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shape)
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [rgb(0x46597A), rgb(0x2B3950)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    let left: CGFloat = 212, width: CGFloat = 600, height: CGFloat = 116
    let tick: CGFloat = 0.62
    for (y, used, color) in [(CGFloat(574), CGFloat(0.36), rgb(0x34C46C)), (CGFloat(334), CGFloat(0.84), rgb(0xEC5244))] {
        capsule(c, CGRect(x: left, y: y, width: width, height: height), rgb(0xFFFFFF, 0.16))
        capsule(c, CGRect(x: left, y: y, width: width * used, height: height), color)
        capsule(c, CGRect(x: left + width * tick - 13, y: y - 34, width: 26, height: height + 68), rgb(0xFFFFFF))
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let c = context.cgContext
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(c)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

if CommandLine.arguments.count > 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    for size in [16, 32, 64, 256, 1024] {
        try png(size: size).write(to: dir.appendingPathComponent("icon-\(size).png"))
    }
}

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote Resources/AppIcon.icns")
