import ExtensionFoundation
import FSKit

@main
struct StreamDriveExtension: UnaryFileSystemExtension {
    var fileSystem: StreamDriveFileSystem { StreamDriveFileSystem() }
}
