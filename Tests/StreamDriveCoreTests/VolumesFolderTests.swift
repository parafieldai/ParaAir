import Foundation
import XCTest
@testable import StreamDriveCore

/// The rules ParaAir's root helper applies in /Volumes, exercised in a temporary folder standing in for /Volumes.
final class VolumesFolderTests: XCTestCase {
    private var root: String!
    private let uid = getuid(), gid = getgid()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("volumes-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testNamesAreOnePlainComponent() {
        for name in ["ParaAir", "Team Drive", "Footage 2", "Ünïcødé"] { XCTAssertTrue(VolumesFolder.isValidName(name), name) }
        for name in ["", ".", "..", ".hidden", "a/b", "a:b", "tab\tname", "bell\u{7}", String(repeating: "x", count: 201)] {
            XCTAssertFalse(VolumesFolder.isValidName(name), name)
        }
    }

    func testFinderNamesBecomeValidFolderNames() {
        XCTAssertEqual(VolumesFolder.folderName(for: "Team/Drive"), "Team-Drive")
        XCTAssertEqual(VolumesFolder.folderName(for: "..Secret"), "Secret")
        XCTAssertEqual(VolumesFolder.folderName(for: "  "), "ParaAir")
        XCTAssertEqual(VolumesFolder.folderName(for: "a:b"), "a-b")
        let long = VolumesFolder.folderName(for: String(repeating: "é", count: 300))
        XCTAssertTrue(VolumesFolder.isValidName(long) && VolumesFolder.isValidName(long + " 9"))
        XCTAssertEqual(VolumesFolder.candidates(for: "Footage"), ["Footage"] + (2...9).map { "Footage \($0)" })
    }

    func testMakesTheFolderForTheUser() throws {
        let path = try VolumesFolder.prepare(name: "Footage", uid: uid, gid: gid, root: root)
        XCTAssertEqual(path, root + "/Footage")
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        XCTAssertEqual(info.st_uid, uid)
    }

    func testReusesTheUsersEmptyFolder() throws {
        try VolumesFolder.prepare(name: "Footage", uid: uid, gid: gid, root: root)
        XCTAssertEqual(try VolumesFolder.prepare(name: "Footage", uid: uid, gid: gid, root: root), root + "/Footage")
    }

    func testRefusesAnythingElseAtThatName() throws {
        try FileManager.default.createDirectory(atPath: root + "/Busy", withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: root + "/Busy/file", contents: Data())
        FileManager.default.createFile(atPath: root + "/File", contents: Data())
        try FileManager.default.createDirectory(atPath: root + "/Target", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root + "/Link", withDestinationPath: root + "/Target")
        for name in ["Busy", "File", "Link"] {
            XCTAssertThrowsError(try VolumesFolder.prepare(name: name, uid: uid, gid: gid, root: root), name) {
                XCTAssertEqual(($0 as? VolumesFolderError)?.code, EEXIST, name)
            }
        }
        // Someone else's folder: the same empty folder, asked for by another user.
        XCTAssertThrowsError(try VolumesFolder.prepare(name: "Target", uid: uid + 1, gid: gid, root: root)) {
            XCTAssertEqual(($0 as? VolumesFolderError)?.code, EEXIST)
        }
    }

    func testRefusesInvalidNamesBeforeTouchingAnything() throws {
        XCTAssertThrowsError(try VolumesFolder.prepare(name: "../escape", uid: uid, gid: gid, root: root)) {
            XCTAssertEqual(($0 as? VolumesFolderError)?.code, EINVAL)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
    }

    func testAFolderThatCantBeHandedOverIsNotLeftBehind() throws {
        guard uid != 0 else { throw XCTSkip("root may give folders to anyone") }
        XCTAssertThrowsError(try VolumesFolder.prepare(name: "Other", uid: uid + 1, gid: gid, root: root)) {
            XCTAssertEqual(($0 as? VolumesFolderError)?.code, EPERM)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
    }

    func testRemovesOnlyTheUsersEmptyFolder() throws {
        try VolumesFolder.prepare(name: "Footage", uid: uid, gid: gid, root: root)
        FileManager.default.createFile(atPath: root + "/Footage/kept", contents: Data())
        XCTAssertThrowsError(try VolumesFolder.remove(name: "Footage", uid: uid, root: root))
        try FileManager.default.removeItem(atPath: root + "/Footage/kept")
        XCTAssertThrowsError(try VolumesFolder.remove(name: "Footage", uid: uid + 1, root: root))
        try VolumesFolder.remove(name: "Footage", uid: uid, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/Footage"))
    }
}
