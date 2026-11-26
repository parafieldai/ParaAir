import XCTest
@testable import StreamDriveCore

/// What Copy Diagnostics puts on the clipboard: the state a support request needs, never tokens, keys, file names or
/// email addresses beyond this Mac's own accounts.
final class SupportDiagnosticsTests: XCTestCase {
    private let home = "/Users/thomas"

    /// The shape of `paraair setup-status --json`.
    private var setupStatus: Data {
        Data("""
        {"accounts":[{"email":"Owner@Example.com","id":"5b0e","issuer":"https://cloud.parafield.ai","state":"signedIn",
                      "stateDirectory":"/Users/thomas/Library/Application Support/ParaAir/Cloud Drives/5b0e","workspaceIds":["ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC"]}],
         "app":{"build":"72","installed":true,"path":"/Applications/ParaAir.app","running":true,"version":"0.1.0"},
         "capabilities":["changes.push","mount.macos26"],"contractVersion":1,
         "extension":{"otherCopies":["/Users/thomas/Downloads/ParaAir.app"],"state":"enabled"},
         "profiles":[{"backend":"paraairCloud","cloudAccountId":"5b0e","cloudDriveId":"drv_1","conflictCopies":false,"healthy":true,
                      "knownToApp":true,"mountPoint":"/Volumes/Client Footage","mounted":true,"profile":"Client-Footage",
                      "stateDirectory":"/Users/thomas/Library/Application Support/ParaAir/Cloud Drives/5b0e","workspaceId":"ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC"}]}
        """.utf8)
    }

    /// The shape of `paraair status NAME --json`, with every field that can name a file or a person filled in.
    private var driveStatus: Data {
        Data("""
        {"backend":"paraairCloud","connectionState":"notProbed","mountPoint":"/Volumes/Client Footage","mounted":true,"profile":"Client-Footage",
         "drive":{"availableBytes":100,"cacheBytes":5,"cacheLimitBytes":10,"conflictedUploads":1,"maxJournalBytes":20,"minFreeBytes":1,
                  "objectGetRequests":3,"objectReadBytes":4,"offline":false,"pendingUploads":2,"pendingWriteBytes":6,"pinnedBytes":7,
                  "stateBytes":8,"totalAllocatedBytes":9,
                  "pins":[{"complete":true,"fileCount":2,"lastError":null,"path":"/Clients/Acme/contract-final.pdf"}],
                  "failingUploads":{"count":2,"errno":13,"oldestChangeNanoseconds":1},
                  "indexBackup":{"lastErrno":5,"lastError":"Couldn’t read /Volumes/Client Footage/Acme/cut.mov"},
                  "ownedElsewhere":{"ownerName":"Lena’s MacBook Pro","seenNanoseconds":1},
                  "uploadToken":"pca_abcdefghijklmnopqrstuvwxyz"}}
        """.utf8)
    }

    private func bundle(logs: SupportDiagnostics.Part = .lines([]), drive: (name: String, status: SupportDiagnostics.Part)? = nil) -> String {
        SupportDiagnostics.text(.init(appVersion: "0.1.0 alpha 11 (72)", clientHeader: "mac/0.1.72", system: "Version 27.3 (Build 27D60)",
                                      createdAt: Date(timeIntervalSince1970: 1_795_000_000), setupStatus: .json(setupStatus),
                                      drive: drive ?? ("Client-Footage", .json(driveStatus)), logs: logs, accountEmails: [], home: home))
    }

    func testDiagnosticsKeepTheStateSupportNeeds() {
        let text = bundle()
        for kept in ["ParaAir: 0.1.0 alpha 11 (72)", "Sent to ParaAir Cloud as: mac/0.1.72", "macOS: Version 27.3 (Build 27D60)",
                     "\"state\" : \"enabled\"", "\"profile\" : \"Client-Footage\"", "\"mountPoint\" : \"/Volumes/Client Footage\"",
                     "\"pendingUploads\" : 2", "\"conflictedUploads\" : 1", "\"errno\" : 13", "\"lastErrno\" : 5", "\"healthy\" : true",
                     "\"email\" : \"Owner@Example.com\"", "## paraair status --json (Client-Footage)", "\"build\" : \"72\"",
                     "\"stateDirectory\" : \"~/Library/Application Support/ParaAir/Cloud Drives/5b0e\"", "~/Downloads/ParaAir.app"] {
            XCTAssertTrue(text.contains(kept), "keeps \(kept)\n\(text)")
        }
        XCTAssertTrue(text.contains(SupportDiagnostics.removedNote), "says what was removed")
    }

    func testDiagnosticsRemoveFileNamesTokensAndOtherPeople() {
        let logs = SupportDiagnostics.Part.lines([
            "2026-11-26T09:00:00Z cloud notice: signed in as owner@example.com, invited lena@studio.example",
            "2026-11-26T09:00:01Z cloud error: Authorization: Bearer pca_secretsecret refresh pcr_another.one read prt1.abc.def",
            "2026-11-26T09:00:02Z mount error: open failed /Volumes/ParaAir/Clients/Acme/contract-final.pdf",
            "2026-11-26T09:00:03Z install error: move failed domain=NSCocoaErrorDomain code=-1 in /Users/thomas/Downloads/ParaAir.app",
            "2026-11-26T09:00:04Z cloud notice: callback http://127.0.0.1:5000/oauth/callback?code=AbC123xyz&state=s1",
            "2026-11-26T09:00:05Z billing: key sk_live_51Habc token eyJhbGciOi.eyJzdWIiOiIx.c2lnbmF0dXJl",
        ])
        let text = bundle(logs: logs)
        for removed in ["contract-final.pdf", "Acme", "cut.mov", "Lena’s MacBook", "lena@studio.example", "pca_", "pcr_", "prt1.abc",
                        "secretsecret", "abcdefghijklmnopqrstuvwxyz", "AbC123xyz", "sk_live_51Habc", "eyJhbGciOi", "/Users/thomas"] {
            XCTAssertFalse(text.contains(removed), "removes \(removed)\n\(text)")
        }
        for kept in ["owner@example.com", "[email]", "Bearer [redacted]", "/Volumes/ParaAir/[path]", "code=-1", "code=[redacted]",
                     "\"pins\" : \"[1 pinned path removed]\"", "\"ownerName\" : \"[removed]\"", "\"lastError\" : \"[removed]\"",
                     "\"uploadToken\" : \"[redacted]\"", "~/Downloads/ParaAir.app"] {
            XCTAssertTrue(text.contains(kept), "shows \(kept)\n\(text)")
        }
    }

    func testDiagnosticsSayWhatIsMissing() {
        let text = SupportDiagnostics.text(.init(appVersion: "Development build", clientHeader: "mac/dev", system: "Version 27.3",
                                                 createdAt: Date(timeIntervalSince1970: 0), setupStatus: .unavailable("The paraair helper isn’t in this build."),
                                                 drive: nil, logs: .unavailable("This app’s log couldn’t be read."),
                                                 accountEmails: ["me@example.com"], home: home))
        XCTAssertTrue(text.contains("The paraair helper isn’t in this build."))
        XCTAssertTrue(text.contains("The selected state folder has no drive."))
        XCTAssertTrue(text.contains("This app’s log couldn’t be read."))
        XCTAssertTrue(bundle(drive: ("Client-Footage", .json(Data("not json".utf8)))).contains("printed something other than JSON"))
        XCTAssertTrue(bundle(logs: .lines([])).hasSuffix("last 30 minutes)\nNone.\n"))
        // The signed-in account's address stays even when setup-status couldn't run.
        let scrubber = SupportDiagnostics.Scrubber(allowedEmails: ["Me@Example.com"], home: home)
        XCTAssertEqual(scrubber.scrub("me@example.com and you@example.com"), "me@example.com and [email]")
        XCTAssertEqual(scrubber.scrub("/Users/thomas"), "~")
        XCTAssertEqual(scrubber.scrub("/Users/thomasina/file"), "/Users/thomasina/file", "only the home folder itself")
    }
}
