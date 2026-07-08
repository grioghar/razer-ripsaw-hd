// Renders the app icon: neon-green angular "R" on a black squircle, Razer-esque.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let green = NSColor(calibratedRed: 0x44 / 255.0, green: 0xD6 / 255.0, blue: 0x2C / 255.0, alpha: 1)

// macOS-style squircle with standard margins
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// Dark background with a subtle top-lit gradient
NSGradient(colors: [NSColor(calibratedWhite: 0.16, alpha: 1),
                    NSColor(calibratedWhite: 0.02, alpha: 1)])!
    .draw(in: squircle, angle: -90)

// Thin green ring inset from the edge
let ringRect = rect.insetBy(dx: 26, dy: 26)
let ring = NSBezierPath(roundedRect: ringRect, xRadius: 160, yRadius: 160)
ring.lineWidth = 7
green.withAlphaComponent(0.45).setStroke()
ring.stroke()

// Glowing "R"
squircle.setClip()
let shadow = NSShadow()
shadow.shadowColor = green.withAlphaComponent(0.85)
shadow.shadowBlurRadius = 70
shadow.shadowOffset = .zero
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 540, weight: .black),
    .foregroundColor: green,
    .shadow: shadow,
]
let letter = NSAttributedString(string: "R", attributes: attrs)
let letterSize = letter.size()
letter.draw(at: NSPoint(x: (CGFloat(size) - letterSize.width) / 2,
                        y: (CGFloat(size) - letterSize.height) / 2))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
