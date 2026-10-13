import SwiftUI
import AppKit

/// Glide brand tokens for SwiftUI. Values come from BrandIconGeometry.palette and the website
/// (site/styles.css), so the app, the icon, the menu mark and paraair.pages.dev share one system:
/// charcoal paper and warm ink in Dark mode, the reverse in Light, sage as the accent.
enum Glide {
    static let charcoal = color(0)
    static let warmWhite = color(1)
    static let green = color(2)

    // Surfaces and ink, as on the website: --paper, --ink, --paper-2 (paper 92% toward ink).
    static let paper = adaptive(dark: 0x20282C, light: 0xF1EFE7)
    static let ink = adaptive(dark: 0xF1EFE7, light: 0x20282C)
    static let surface = adaptive(dark: 0x2E3639, light: 0xDEDDD6)
    static let rule = adaptive(dark: 0x394043, light: 0xCFCFC9)
    /// Supporting text. The system's secondary label is about 3:1 on the light paper; this is at
    /// least 4.5:1 on the paper and on the grouped rows in both modes.
    static let quiet = adaptive(dark: 0xB1B3B0, light: 0x5C6162)

    /// The call-to-action fill and its label (--accent, --accent-ink): sage on charcoal in Dark
    /// mode, charcoal on warm white in Light. 8:1 and 15:1.
    static let accent = adaptive(dark: 0x9AC7B4, light: 0x20282C)
    static let accentInk = adaptive(dark: 0x20282C, light: 0xF1EFE7)
    /// Tint for native controls (switches, checkboxes, progress bars). AppKit draws white
    /// glyphs on the tint, so Dark mode uses a deeper sage: white on it is 3.7:1, and it is
    /// 3.3:1 against the grouped rows.
    static let controlTint = adaptive(dark: 0x6C8B81, light: 0x20282C)

    /// Status tones, tuned to the paper: each is at least 4.3:1 on the grouped rows.
    static let good = adaptive(dark: 0x9AC7B4, light: 0x3F6B5A)
    static let attention = adaptive(dark: 0xE2B46B, light: 0x8A5A12)
    static let problem = adaptive(dark: 0xEE8F7E, light: 0xA63A2A)

    private static func color(_ index: Int) -> Color {
        let rgb = BrandIconGeometry.palette[index]
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        func ns(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        let darkColor = ns(dark), lightColor = ns(light)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    /// Fine grain for the paper, like the website's noise layer: mid-grey specks with varied
    /// alpha, drawn once. 160 pixels square, shown at 80 points so it stays sharp on Retina.
    static let grain: NSImage = {
        let side = 160
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x5DEECE66D
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let alpha = UInt8(truncatingIfNeeded: (seed >> 33) % 230)
            // Premultiplied mid grey.
            let grey = UInt8(Int(alpha) / 2)
            pixels[index] = grey; pixels[index + 1] = grey; pixels[index + 2] = grey; pixels[index + 3] = alpha
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { return NSImage(size: NSSize(width: 80, height: 80)) }
        return NSImage(cgImage: image, size: NSSize(width: 80, height: 80))
    }()
}

extension Font {
    /// The website's display face: New York, medium weight.
    static func glideDisplay(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .serif, weight: weight)
    }
    /// Section and sheet headings.
    static let glideHeading = Font.system(.title3, design: .serif, weight: .semibold)
}

/// The window surface: paper with the grain behind everything.
struct GlidePaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Glide.paper
            .overlay(Image(nsImage: Glide.grain).resizable(resizingMode: .tile)
                .opacity(scheme == .dark ? 0.07 : 0.05))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    /// Paper for a whole window, sheet or panel. Grouped forms keep their native rows; with the
    /// scroll background hidden the rows sit on the paper as a tonal step. Text keeps the system
    /// label colours, so values stay a step quieter than their labels.
    func glideSurface() -> some View {
        scrollContentBackground(.hidden)
            .background { GlidePaper() }
    }

    /// Brand tint for switches, checkboxes and progress bars only. A window-wide tint would also
    /// recolour push-button labels and pop-up values, which then read as disabled.
    func glideControlTint() -> some View {
        tint(Glide.controlTint)
    }
}

/// The badge's chamfered square, as a shape: the website's call-to-action silhouette.
struct Chamfer: InsettableShape {
    var cut: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Chamfer {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in fullRect: CGRect) -> Path {
        let rect = fullRect.insetBy(dx: insetAmount, dy: insetAmount)
        // Insetting moves each diagonal in by the inset times (√2 − 1) relative to the cut.
        let c = min(max(cut - insetAmount * 0.414, 0), rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        path.closeSubpath()
        return path
    }
}

/// The one prominent action per view: a chamfered sage (Dark) or charcoal (Light) button, as
/// on the website. On hover a band of light crosses the face once; the button never moves.
struct GlideProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlideProminentButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == GlideProminentButtonStyle {
    static var glideProminent: GlideProminentButtonStyle { GlideProminentButtonStyle() }
}

private struct GlideProminentButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1.2

    private var metrics: (font: CGFloat, horizontal: CGFloat, vertical: CGFloat, cut: CGFloat) {
        switch controlSize {
        case .mini, .small: return (11, 10, 4, 5)
        case .large, .extraLarge: return (15, 20, 10, 8)
        default: return (13, 14, 6, 6)
        }
    }

    var body: some View {
        let metrics = self.metrics
        let shape = Chamfer(cut: metrics.cut)
        configuration.label
            .font(.system(size: metrics.font, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .foregroundStyle(isEnabled ? Glide.accentInk : Glide.ink.opacity(0.42))
            .background(shape.fill(isEnabled ? Glide.accent : Glide.ink.opacity(0.1)))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                           .init(color: Glide.paper.opacity(0.18), location: 0.5),
                                           .init(color: .clear, location: 0.7)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width)
                        .offset(x: sweep * proxy.size.width)
                }
                .allowsHitTesting(false)
            }
            .overlay(shape.fill(Glide.paper.opacity(configuration.isPressed && isEnabled ? 0.2 : 0)))
            .clipShape(shape)
            .contentShape(shape)
            .onHover { inside in
                // Leaving resets the band off the left edge without animating, so the next hover
                // sweeps again; Reduce Motion keeps it there.
                guard inside, isEnabled, !reduceMotion else { sweep = -1.2; return }
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.7)) { sweep = 1.2 }
            }
    }
}

/// The Glide mark drawn from the shared polygon geometry. `badge` includes the charcoal
/// square; without it the two flight polygons render bare: in ink and sage (the website's
/// mark) by default, or as one template shape.
struct GlideMark: View {
    var badge = true
    var template = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let polygons = badge ? [BrandIconGeometry.badge] + BrandIconGeometry.mark : BrandIconGeometry.mark
            let bounds = badge ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : markBounds
            let scale = side / max(bounds.width, bounds.height)
            let inset = CGPoint(x: origin.x + (side - bounds.width * scale) / 2,
                                y: origin.y + (side - bounds.height * scale) / 2)
            for polygon in polygons {
                var path = Path()
                for (index, point) in polygon.points.enumerated() {
                    let mapped = CGPoint(x: inset.x + (point.x - bounds.minX) * scale,
                                         y: inset.y + (point.y - bounds.minY) * scale)
                    if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                }
                path.closeSubpath()
                let fill: Color
                if badge {
                    fill = [Glide.charcoal, Glide.warmWhite, Glide.green][polygon.color]
                } else if template {
                    fill = .primary
                } else {
                    fill = polygon.color == 1 ? Glide.ink : Glide.green
                }
                context.fill(path, with: .color(fill))
            }
        }
        .accessibilityHidden(true)
    }

    private var markBounds: CGRect {
        let points = BrandIconGeometry.mark.flatMap(\.points)
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
