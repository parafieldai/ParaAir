import XCTest
@testable import StreamDriveCLI

final class CLIParserTests: XCTestCase {
    func testNoArgumentsShowsHelp() throws {
        XCTAssertEqual(try CLIParser.parse([]).command, .help(nil))
    }

    func testGlobalOptionsAreAcceptedAfterCommand() throws {
        let invocation = try CLIParser.parse(["status", "home", "--json", "--state-dir", "/tmp/drive state"])
        XCTAssertEqual(invocation.command, .status(profile: "home"))
        XCTAssertTrue(invocation.json)
        XCTAssertEqual(invocation.stateDirectory, "/tmp/drive state")
    }

    func testExplicitProfileFlagAndPositionalPath() throws {
        XCTAssertEqual(
            try CLIParser.parse(["ls", "--profile", "home", "/a file"]).command,
            .list(profile: "home", path: "/a file")
        )
    }

    func testMountRequiresExplicitProfile() {
        XCTAssertThrowsError(try CLIParser.parse(["mount"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("profile"))
        }
    }

    func testUnknownFlagsAreRejected() {
        XCTAssertThrowsError(try CLIParser.parse(["mount", "home", "--unsafe"]))
    }

    func testUnknownOptionValuesAreNotEchoed() {
        XCTAssertThrowsError(try CLIParser.parse(["connect", "home", "--password=DO_NOT_ECHO"])) { error in
            XCTAssertFalse(error.localizedDescription.contains("DO_NOT_ECHO"))
        }
    }

    func testProfileCannotEscapeStateDirectory() {
        for profile in ["../home", "/home", "", "a/b"] {
            XCTAssertThrowsError(try CLIParser.parse(["mount", profile]))
        }
    }

    func testPathsRemainSingleArguments() throws {
        XCTAssertEqual(
            try CLIParser.parse(["reveal", "home", "/a file/$(touch bad)"]).command,
            .reveal(profile: "home", path: "/a file/$(touch bad)")
        )
    }

    func testDuplicateGlobalOptionsAreRejected() {
        XCTAssertThrowsError(try CLIParser.parse(["--state-dir", "/one", "status", "--state-dir", "/two"]))
    }

    func testConflictingProfileSourcesAreRejected() {
        XCTAssertThrowsError(try CLIParser.parse(["mount", "one", "--profile", "two"]))
    }

    func testFlagValuesCannotConsumeAnotherFlag() {
        XCTAssertThrowsError(try CLIParser.parse(["status", "--state-dir", "--json"]))
    }

    func testExtraPositionalsAreRejected() {
        XCTAssertThrowsError(try CLIParser.parse(["mount", "home", "unexpected"]))
    }
}
