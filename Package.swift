// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParaAir",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StreamDriveCore", targets: ["StreamDriveCore"]),
        .executable(name: "paraair", targets: ["StreamDriveCLI"]),
        .executable(name: "streamdrive", targets: ["StreamDriveCLI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "StreamDriveCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "StreamDriveCLI", dependencies: ["StreamDriveCore"]),
        .testTarget(name: "StreamDriveCoreTests", dependencies: ["StreamDriveCore"]),
        .testTarget(name: "StreamDriveCLITests", dependencies: ["StreamDriveCLI", "StreamDriveCore"])
    ],
    swiftLanguageModes: [.v5]
)
