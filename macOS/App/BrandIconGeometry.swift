import AppKit

/// Exactly three flat fills and straight-edged polygons, on a top-left canvas.
enum BrandIconGeometry {
    struct Polygon {
        let color: Int
        let points: [CGPoint]
    }
    static let palette: [UInt32] = [0x20282C, 0xF1EFE7, 0x9AC7B4]
    static let badge = Polygon(color: 0, points: [
        CGPoint(x: 100, y: 76), CGPoint(x: 924, y: 76),
        CGPoint(x: 948, y: 100), CGPoint(x: 948, y: 924),
        CGPoint(x: 924, y: 948), CGPoint(x: 100, y: 948),
        CGPoint(x: 76, y: 924), CGPoint(x: 76, y: 100),
    ])
    static let mark: [Polygon] = [
        Polygon(color: 1, points: [
            CGPoint(x: 252, y: 432), CGPoint(x: 706, y: 282),
            CGPoint(x: 568, y: 580), CGPoint(x: 496, y: 490),
        ]),
        Polygon(color: 2, points: [
            CGPoint(x: 496, y: 490), CGPoint(x: 568, y: 580),
            CGPoint(x: 408, y: 742), CGPoint(x: 420, y: 538),
        ]),
    ]
    static func color(_ index: Int) -> CGColor {
        let rgb = palette[index]
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
            CGFloat((rgb >> 16) & 255) / 255,
            CGFloat((rgb >> 8) & 255) / 255,
            CGFloat(rgb & 255) / 255, 1,
        ])!
    }
    static func draw(in context: CGContext, rect: CGRect, template: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        if template {
            let points = mark.flatMap(\.points)
            let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
            let scale = min(rect.width / (maxX - minX), rect.height / (maxY - minY))
            context.translateBy(x: rect.midX - (minX + maxX) / 2 * scale,
                                y: rect.midY + (minY + maxY) / 2 * scale)
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: rect.width / 1024, y: -rect.height / 1024)
        }
        if template { context.beginPath() }
        for polygon in template ? mark : [badge] + mark {
            guard let first = polygon.points.first else { continue }
            if !template { context.beginPath() }
            context.move(to: first)
            for point in polygon.points.dropFirst() { context.addLine(to: point) }
            context.closePath()
            if !template {
                context.setFillColor(color(polygon.color))
                context.fillPath()
            }
        }
        if template {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        }
    }
    static var svg: String {
        let elements = ([badge] + mark).map { polygon in
            let points = polygon.points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
            let fill = String(format: "#%06X", palette[polygon.color])
            return "  <polygon fill=\"\(fill)\" points=\"\(points)\"/>"
        }.joined(separator: "\n")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
          <title>ParaAir</title>
        \(elements)
        </svg>

        """
    }
}
