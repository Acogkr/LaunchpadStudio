import AppKit

// The background contains only type and a direction cue. Finder supplies the
// actual draggable app and Applications folder icons above this image.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let canvas = NSSize(width: 640, height: 400)
var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale,
        pixelsHigh: 400 * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = canvas
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas).fill()
    func centered(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, gray: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedWhite: gray, alpha: 1)
        ]
        let value = NSAttributedString(string: text, attributes: attributes)
        let dimensions = value.size()
        value.draw(at: NSPoint(x: (canvas.width - dimensions.width) / 2,
                              y: canvas.height - top - dimensions.height))
    }
    centered("Launchpad Studio", top: 44, size: 22, weight: .medium, gray: 0.15)
    let arrow = NSBezierPath()
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    let y: CGFloat = 400 - 186
    arrow.move(to: NSPoint(x: 296, y: y))
    arrow.line(to: NSPoint(x: 344, y: y))
    arrow.move(to: NSPoint(x: 335, y: y + 9))
    arrow.line(to: NSPoint(x: 344, y: y))
    arrow.line(to: NSPoint(x: 335, y: y - 9))
    NSColor(calibratedWhite: 0.64, alpha: 1).setStroke()
    arrow.stroke()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    representations.append(bitmap)
}
try NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [.compressionFactor: 1])!
    .write(to: output.appendingPathComponent("background.tiff"))
