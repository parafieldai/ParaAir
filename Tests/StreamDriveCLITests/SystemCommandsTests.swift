import XCTest
@testable import StreamDriveCLI

final class SystemCommandsTests: XCTestCase {
    func testArgumentsArePassedWithoutShellInterpretation() throws {
        let value = "spaces ; $(printf injected) `printf injected`"
        let output = try SystemCommands.run(executable: "/usr/bin/printf", arguments: ["%s", value])
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout, value)
        XCTAssertEqual(output.stderr, "")
    }

    func testSubprocessDeadlineIsEnforced() {
        let started = Date()
        XCTAssertThrowsError(try SystemCommands.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testMountPlanUsesExplicitResourceAndSafeOptions() {
        XCTAssertEqual(
            MountController.mountArguments(profile: "home", stateRoot: "/a state", mountPoint: "/a drive"),
            ["-F", "-t", "streamdrive", "-o", "nosuid,nodev,-p=home", "/a state", "/a drive"]
        )
    }
}
