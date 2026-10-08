import XCTest
@testable import StreamDriveCore

final class PathTests: XCTestCase {
    func testDrivePathsCannotEscapeOrAddressInternalFiles() throws {
        XCTAssertEqual(try canonicalPath("//photos//image.jpg/"), "/photos/image.jpg")
        for path in ["relative", "/../secret", "/a/./b", "/.streamdrive/locks", "/a\0b"] {
            XCTAssertThrowsError(try canonicalPath(path))
        }
    }
}
