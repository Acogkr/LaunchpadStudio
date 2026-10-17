import AppKit

func studioIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.lockFocus()
    // Match the 824/1024 opaque silhouette of standard macOS app icons.
    let rect = NSRect(x: 50, y: 50, width: 412, height: 412)
    let path = NSBezierPath(roundedRect: rect, xRadius: 94, yRadius: 94)
    NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.86, alpha: 1))!.draw(
        in: path, angle: -90)
    NSColor(white: 0.72, alpha: 0.6).setStroke()
    path.lineWidth = 2
    path.stroke()
    for x in 0..<3 {
        for y in 0..<3 {
            let box = NSBezierPath(
                roundedRect: NSRect(x: 127 + x * 91, y: 127 + y * 91, width: 76, height: 76), xRadius: 18, yRadius: 18)
            if x == 0 && y == 2 {
                NSColor(red: 0.25, green: 0.49, blue: 0.84, alpha: 1).setFill()
            } else {
                NSColor(white: 0.37 + Double(y) * 0.06, alpha: 1).setFill()
            }
            box.fill()
        }
    }
    image.unlockFocus()
    return image
}
