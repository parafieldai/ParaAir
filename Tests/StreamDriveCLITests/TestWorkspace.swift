import Foundation

func testWorkspaceRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".runtime", isDirectory: true)
}
