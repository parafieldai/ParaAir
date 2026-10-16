import XCTest
@testable import StreamDriveCore

final class ParaAirBundleTests: XCTestCase {
    func testExtensionIdentifierFollowsTheAppIdentity() {
        XCTAssertEqual(ParaAirBundle.filesystemIdentifier(forApp: "dev.streamdrive.app"), "dev.streamdrive.app.filesystem")
        XCTAssertEqual(ParaAirBundle.filesystemIdentifier(forApp: "dev.streamdrive.app.dev"), "dev.streamdrive.app.dev.filesystem")
        // Anything else (the CLI, a test runner) falls back to the release extension.
        XCTAssertEqual(ParaAirBundle.filesystemIdentifier(forApp: "dev.streamdrive.app.cli"), "dev.streamdrive.app.filesystem")
        XCTAssertEqual(ParaAirBundle.filesystemIdentifier(forApp: nil), "dev.streamdrive.app.filesystem")
    }

    func testBothBuildKindsMountedVolumesAreRecognised() {
        XCTAssertTrue(ParaAirBundle.volumeTypes.isSuperset(of: ["streamdrive", "streamdrive-dev"]))
        XCTAssertFalse(ParaAirBundle.volumeTypes.contains("apfs"))
    }
}
