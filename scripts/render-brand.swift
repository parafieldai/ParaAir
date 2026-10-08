import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct BrandAssetRenderer {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, let size = Int(args[1]), size >= 16, size <= 1024 else {
            throw NSError(domain: "ParaAirBrand", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: render-brand SIZE OUTPUT.png"])
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ParaAirBrand", code: 2)
        }
        // Keep palette pixels exact at every export size. The outside is clear.
        context.setShouldAntialias(false)
        BrandIconGeometry.draw(in: context, rect: CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { throw NSError(domain: "ParaAirBrand", code: 3) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ParaAirBrand", code: 4) }
        if size == 1024 {
            let svg = URL(fileURLWithPath: args[2]).deletingPathExtension().appendingPathExtension("svg")
            try BrandIconGeometry.svg.write(to: svg, atomically: true, encoding: .utf8)
        }
    }
}
