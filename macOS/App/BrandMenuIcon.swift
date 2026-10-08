import AppKit

/// The application icon's polygon A, rendered as a system-color template.
@MainActor
enum BrandMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            BrandIconGeometry.draw(in: context, rect: rect.insetBy(dx: 1.5, dy: 1.5), template: true)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ParaAir"
        return image
    }()
}
