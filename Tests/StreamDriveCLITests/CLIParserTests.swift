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

    func testCloudOptionsParse() throws {
        let account = "0f8fad5b-d9cb-469f-a165-70867728950e", drive = "3f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c"
        XCTAssertEqual(try CLIParser.parse(["connect", "studio", "--cloud-account", account, "--cloud-drive=" + drive]).command,
                       .connect(ConnectArguments(profile: "studio", values: ["cloud-account": account, "cloud-drive": drive], overwrite: false)))
        XCTAssertEqual(try CLIParser.parse(["cloud-accounts", "--json"]).command, .cloudAccounts)
        XCTAssertEqual(try CLIParser.parse(["trash", "studio"]).command, .trash(profile: "studio"))
        XCTAssertEqual(try CLIParser.parse(["restore", "studio", "42"]).command, .restore(profile: "studio", nodeID: 42, to: nil))
        XCTAssertEqual(try CLIParser.parse(["restore", "--profile", "studio", "42", "--to", "/a b.mov"]).command,
                       .restore(profile: "studio", nodeID: 42, to: "/a b.mov"))
        for invalid in [["connect", "studio", "--cloud-drive", drive], ["connect", "studio", "--cloud-account", account.uppercased()],
                        ["connect", "studio", "--cloud-account", "../x"], ["restore", "studio"], ["restore", "studio", "0"],
                        ["restore", "studio", "-1"], ["restore", "studio", "42", "43"], ["restore", "studio", "9007199254740992"],
                        ["trash"], ["trash", "studio", "extra"], ["cloud-accounts", "extra"]] {
            XCTAssertThrowsError(try CLIParser.parse(invalid), invalid.joined(separator: " "))
        }
    }

    func testParsesStoredDrivesAndRecover() throws {
        XCTAssertEqual(try CLIParser.parse(["stored-drives", "--connection", "abc"]).command,
                       .storedDrives(connection: "abc", library: nil))
        XCTAssertEqual(try CLIParser.parse(["recover", "Studio", "--connection", "abc", "--volume", "streamdrive-x1", "--backup",
                                            "meta/dump-2026-10-18-120000.json.gz"]).command,
                       .recover(profile: "Studio", connection: "abc", volume: "streamdrive-x1",
                                backup: "meta/dump-2026-10-18-120000.json.gz", takeOver: false, library: nil))
        XCTAssertEqual(try CLIParser.parse(["recover", "Studio", "--connection", "abc", "--volume", "streamdrive-x1", "--take-over"]).command,
                       .recover(profile: "Studio", connection: "abc", volume: "streamdrive-x1", backup: nil, takeOver: true, library: nil))
        XCTAssertThrowsError(try CLIParser.parse(["recover", "Studio", "--connection", "abc"]))
        XCTAssertThrowsError(try CLIParser.parse(["stored-drives"]))
        XCTAssertThrowsError(try CLIParser.parse(["stored-drives", "extra", "--connection", "abc"]))
    }
}
