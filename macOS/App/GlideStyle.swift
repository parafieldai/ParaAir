import SwiftUI
import AppKit

/// Glide brand tokens for SwiftUI. Values come from BrandIconGeometry.palette so the
/// app, icon and menu mark share one source. Green is a brand detail, never the app's
/// accent colour: controls keep the system accent so they follow the user's setting.
enum Glide {
    static let charcoal = color(0)
    static let warmWhite = color(1)
    static let green = color(2)

    private static func color(_ index: Int) -> Color {
        let rgb = BrandIconGeometry.palette[index]
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

/// The Glide mark drawn from the shared polygon geometry. `badge` includes the charcoal
/// square; without it the two flight polygons render as one template shape.
struct GlideMark: View {
    var badge = true

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
                let fill: Color = badge ? [Glide.charcoal, Glide.warmWhite, Glide.green][polygon.color] : .primary
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
