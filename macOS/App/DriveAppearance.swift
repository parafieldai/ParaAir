import AppKit
import ImageIO
import StreamDriveCore

/// Custom artwork is a bounded local settings file, not a remote volume file.
@MainActor
struct DriveAppearance {
    let stateRoot: URL

    private func iconURL(_ profile: DriveProfile) throws -> URL {
        try DriveProfile.validateName(profile.name)
        let directory = stateRoot.appendingPathComponent("appearance", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            guard (try FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory else {
                throw DriveError(EACCES, "Drive appearance must use a local settings directory")
            }
        }
        return directory.appendingPathComponent(profile.name + ".png")
    }
    func customPNG(_ profile: DriveProfile) throws -> Data? {
        let url = try iconURL(profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else {
            throw DriveError(EINVAL, "The saved drive icon is invalid")
        }
        let data = try Data(contentsOf: url)
        guard NSImage(data: data) != nil else { throw DriveError(EINVAL, "The saved drive icon is invalid") }
        return data
    }
    func image(_ profile: DriveProfile) -> NSImage {
        if let data = try? customPNG(profile), let image = NSImage(data: data) { return image }
        return NSImage(data: (try? Self.defaultPNG()) ?? Data()) ?? NSImage(size: NSSize(width: 256, height: 256))
    }
    func iconData(_ profile: DriveProfile) throws -> Data {
        try Self.iconFamily(png: customPNG(profile) ?? Self.defaultPNG())
    }
    func saveIcon(_ png: Data, profile: DriveProfile) throws {
        guard png.count <= 1_048_576, NSImage(data: png) != nil else { throw DriveError(EINVAL, "Invalid drive icon") }
        let url = try iconURL(profile)
        try prepareDirectory(url.deletingLastPathComponent())
        if (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
            throw DriveError(EACCES, "The saved drive icon must not be a symbolic link")
        }
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func resetIcon(_ profile: DriveProfile) throws {
        let url = try iconURL(profile)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func prepareDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory else {
                throw DriveError(EACCES, "Drive appearance must use a local settings directory")
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    static func importPNG(from url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 8_388_608,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw DriveError(EINVAL, "Choose a PNG, JPEG, HEIC or TIFF image smaller than 8 MiB")
        }
        return try render(NSImage(cgImage: image, size: .zero))
    }
    static func defaultPNG() throws -> Data {
        if let url = Bundle.main.url(forResource: "ParaAirDriveIcon", withExtension: "png") {
            return try Data(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: "ParaAirIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return try render(image)
        }
        guard let image = NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: "Cloud drive")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue])) else {
            throw DriveError(EIO, "The default drive icon is unavailable")
        }
        return try render(image, inset: 22)
    }
    private static func render(_ image: NSImage, inset: CGFloat = 0) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw DriveError(EIO, "Cannot prepare the drive icon")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let available = 256 - 2 * inset
        let size = image.size
        let scale = available / max(size.width, size.height, 1)
        let width = size.width * scale, height = size.height * scale
        image.draw(in: NSRect(x: (256 - width) / 2, y: (256 - height) / 2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DriveError(EIO, "Cannot encode the drive icon")
        }
        return data
    }
    static func iconFamily(png: Data) throws -> Data {
        guard png.count <= 1_048_560 else { throw DriveError(EINVAL, "Drive icon is too large") }
        func size(_ value: Int) -> Data {
            var value = UInt32(value).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        return Data("icns".utf8) + size(png.count + 16) + Data("ic08".utf8) + size(png.count + 8) + png
    }
}
