// Renders the disk image window background: swift scripts/dmg-background.swift OUT.png SCALE
// 660 x 400 points. The Glide mark points from the app (left) to Applications (right). The sage
// mid tone keeps Finder's own icon labels readable in both appearances: they are black in Light
// mode and white in Dark mode, about 4.5:1 against #587E6E either way.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]), scale >= 1 else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift OUT.png SCALE\n".utf8)); exit(2)
}
let width = 660.0, height = 400.0
let iconRow = 140.0          // icon centres in scripts/dmg-settings.py, from the top. Everything sits in
                             // the top 300 points: Finder on macOS 27 adds a toolbar band and a bottom bar
                             // to disk image windows, leaving about 300 of the 400 points visible.
let paper = NSColor(srgbRed: 0x58 / 255, green: 0x7E / 255, blue: 0x6E / 255, alpha: 1)
let ink = NSColor(srgbRed: 0xF1 / 255, green: 0xEF / 255, blue: 0xE7 / 255, alpha: 1)
let sage = NSColor(srgbRed: 0x9A / 255, green: 0xC7 / 255, blue: 0xB4 / 255, alpha: 1)

// Draw in sRGB so the colours land exactly; a calibrated or device space shifts them.
let cg = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
// Top-left origin in points, so positions read like the Finder icon coordinates.
cg.scaleBy(x: scale, y: scale)
cg.translateBy(x: 0, y: height)
cg.scaleBy(x: 1, y: -1)
let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
NSGraphicsContext.current = flipped

paper.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Fine grain, deterministic, so every build produces the same image.
var seed: UInt64 = 0x5DEECE66D
func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
for _ in 0..<Int(width * height / 9) {
    let light = next() < 0.5
    (light ? NSColor.white : NSColor.black).withAlphaComponent(0.035).setFill()
    NSRect(x: next() * width, y: next() * height, width: 1 / scale * 1.5, height: 1 / scale * 1.5).fill()
}

// The Glide mark (site/glide.svg, viewBox 454 x 460), turned 45 degrees so its nose points right.
let markA: [CGPoint] = [CGPoint(x: 0, y: 150), CGPoint(x: 454, y: 0), CGPoint(x: 316, y: 298), CGPoint(x: 244, y: 208)]
let markB: [CGPoint] = [CGPoint(x: 244, y: 208), CGPoint(x: 316, y: 298), CGPoint(x: 156, y: 460), CGPoint(x: 168, y: 256)]
cg.saveGState()
cg.translateBy(x: width / 2, y: iconRow)
cg.rotate(by: .pi / 4)
let markScale = 58.0 / 460.0
cg.scaleBy(x: markScale, y: markScale)
cg.translateBy(x: -227, y: -230)
for (points, color) in [(markA, ink), (markB, sage)] {
    let path = NSBezierPath()
    path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
    color.setFill(); path.fill()
}
cg.restoreGState()

let caption = "Drag ParaAir into Applications" as NSString
let style = NSMutableParagraphStyle(); style.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                 .foregroundColor: ink, .paragraphStyle: style, .kern: 0.1]
caption.draw(in: NSRect(x: 0, y: 252, width: width, height: 26), withAttributes: attributes)

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
rep.size = NSSize(width: width, height: height)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[1]))
