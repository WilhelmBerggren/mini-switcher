#!/usr/bin/swift
// Generates AppIcon.icns from the rectangle.2.swap SF Symbol.
// Run once: swift generate_icon.swift  (or via `make AppIcon.icns`)
import Cocoa

_ = NSApplication.shared  // required for SF Symbol rendering

let outDir = "AppIcon.iconset"
let fm = FileManager.default
try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true, attributes: nil)

// Each entry: (iconset filename, pixel size of that PNG)
let entries: [(String, Int)] = [
    ("icon_16x16",       16),  ("icon_16x16@2x",    32),
    ("icon_32x32",       32),  ("icon_32x32@2x",    64),
    ("icon_128x128",    128),  ("icon_128x128@2x", 256),
    ("icon_256x256",    256),  ("icon_256x256@2x", 512),
    ("icon_512x512",    512),  ("icon_512x512@2x",1024),
]

for (name, px) in entries {
    let sz = CGFloat(px)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded blue background
    let r = sz * 0.22
    let bg = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: sz, height: sz),
                          xRadius: r, yRadius: r)
    NSColor(calibratedRed: 0.22, green: 0.44, blue: 0.95, alpha: 1).setFill()
    bg.fill()

    // White SF Symbol, centered
    let symPt = sz * 0.52
    let cfg = NSImage.SymbolConfiguration(pointSize: symPt, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: CGRect(x: (sz - s.width) / 2, y: (sz - s.height) / 2,
                            width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("  \(outDir)/\(name).png")
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", outDir, "-o", "AppIcon.icns"]
try! p.run()
p.waitUntilExit()

try! fm.removeItem(atPath: outDir)
print("AppIcon.icns generated")
