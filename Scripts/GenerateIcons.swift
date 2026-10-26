import AppKit

// Original vector artwork; no images or fonts are downloaded.
let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("RedQuits3.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(size: Int, draw: () -> Void) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon canvas") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    precondition(bitmap.pixelsWide == size && bitmap.pixelsHigh == size)
    return data
}

func cross(in rect: NSRect, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: NSPoint(x: rect.minX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    color.setStroke()
    path.stroke()
}

func appIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedWhite: 0.24, alpha: 1), ending: NSColor(calibratedWhite: 0.10, alpha: 1))!
        .draw(in: tile, angle: -90)
    let circle = NSBezierPath(ovalIn: NSRect(x: 227, y: 250, width: 570, height: 570))
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.39, blue: 0.37, alpha: 1),
               ending: NSColor(calibratedRed: 0.87, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: circle, angle: -90)
    cross(in: NSRect(x: 416, y: 439, width: 192, height: 192), width: 55, color: .white)
    let label = "3" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 108, weight: .bold),
                                                   .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
    label.draw(at: NSPoint(x: 758, y: 154), withAttributes: attributes)
}

func statusIcon() {
    let ring = NSBezierPath(ovalIn: NSRect(x: 100, y: 100, width: 824, height: 824))
    ring.lineWidth = 88
    NSColor.black.setStroke()
    ring.stroke()
    cross(in: NSRect(x: 370, y: 370, width: 284, height: 284), width: 88, color: .black)
}

for size in [16, 32, 128, 256, 512] {
    try png(size: size, draw: appIcon).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size: size * 2, draw: appIcon).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(size: 1024, draw: appIcon).write(to: assets.appendingPathComponent("RedQuits3.png"))
try png(size: 18, draw: statusIcon).write(to: assets.appendingPathComponent("StatusIcon.png"))
try png(size: 36, draw: statusIcon).write(to: assets.appendingPathComponent("StatusIcon@2x.png"))
print("Generated app iconset and 1x/2x menu-bar icons")
