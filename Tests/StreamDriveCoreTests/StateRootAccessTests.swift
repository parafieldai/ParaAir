import Foundation
import XCTest
@testable import StreamDriveCore

final class StateRootAccessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("state-root-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    func testWritableFolderAnswersYesAndLeavesNothingBehind() throws {
        XCTAssertTrue(StateRootAccess.canCreateFiles(in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testReadOnlyFolderAnswersNo() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertFalse(StateRootAccess.canCreateFiles(in: folder))
    }

    func testMissingFolderAnswersNo() {
        XCTAssertFalse(StateRootAccess.canCreateFiles(in: folder.appendingPathComponent("missing")))
    }
}
