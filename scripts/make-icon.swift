import AppKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
guard let logo = NSImage(contentsOf: resources.appendingPathComponent("PelicanLogo.svg")) else { fatalError("PelicanLogo.svg is required") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let side = CGFloat(pixels)
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor(calibratedRed: 245/255, green: 241/255, blue: 231/255, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: side * 0.04, dy: side * 0.04), xRadius: side * 0.22, yRadius: side * 0.22).fill()
        let width = side * 0.78, height = width * 360/440
        logo.draw(in: NSRect(x: (side-width)/2, y: (side-height)/2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
