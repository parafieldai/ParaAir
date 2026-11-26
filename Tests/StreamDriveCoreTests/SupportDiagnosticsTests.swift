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
                     "~/Downloads/ParaAir.app"] {
            XCTAssertTrue(text.contains(kept), "shows \(kept)\n\(text)")
        }
        XCTAssertFalse(text.contains("uploadToken"), "a field the status doesn't document is left out\n\(text)")
    }

    /// The default drive name has a space, and file and folder names have spaces, apostrophes and quotes.
    func testDiagnosticsRemovePathsInsideDrivesWithSpaces() {
        let scrubber = SupportDiagnostics.Scrubber(allowedEmails: [], home: home, mountPoints: ["/Volumes/ParaAir Cloud/"])
        XCTAssertEqual(scrubber.scrub("open failed /Volumes/ParaAir Cloud/Q3 Board Deck.pdf"), "open failed /Volumes/ParaAir Cloud/[path]")
        XCTAssertEqual(scrubber.scrub("/volumes/paraair cloud/Q3 Board Deck.pdf"), "/volumes/paraair cloud/[path]", "APFS names ignore case")
        for name in ["Lena's Notes/plan.txt", "Lena’s Notes/plan.txt"] {
            let line = scrubber.scrub("open failed /Volumes/ParaAir Cloud/" + name + " errno=13")
            XCTAssertEqual(line, "open failed /Volumes/ParaAir Cloud/[path]", "an apostrophe doesn't end the path")
        }
        XCTAssertEqual(scrubber.scrub("Couldn’t open “/Volumes/ParaAir Cloud/Acme/cut.mov” because it’s busy."),
                       "Couldn’t open “/Volumes/ParaAir Cloud/[path]” because it’s busy.", "a closing curly quote ends it")
        XCTAssertEqual(scrubber.scrub(#"{"file":"/Volumes/ParaAir Cloud/Acme/cut 2.mov","errno":5}"#),
                       #"{"file":"/Volumes/ParaAir Cloud/[path]","errno":5}"#, "a closing straight quote ends it")
        // Drives this Mac doesn't list keep only their name too.
        let other = SupportDiagnostics.Scrubber(allowedEmails: [], home: home)
        XCTAssertEqual(other.scrub("open failed /Volumes/Client Footage/Acme/cut.mov"), "open failed /Volumes/Client Footage/[path]")
        XCTAssertEqual(other.scrub("open failed /Volumes/Work/Q3 Board Deck.pdf"), "open failed /Volumes/Work/[path]")
        XCTAssertEqual(other.scrub("open failed /Volumes/Work/Lena's Notes/plan.txt"), "open failed /Volumes/Work/[path]")
        XCTAssertEqual(other.scrub("first line /Volumes/Work/a b.pdf\nsecond line"), "first line /Volumes/Work/[path]\nsecond line")
        // The review's examples.
        XCTAssertEqual(other.scrub("/Volumes/Client Footage/Acme/contract.pdf"), "/Volumes/Client Footage/[path]")
        XCTAssertEqual(other.scrub("/Volumes/ParaAir/Client Files/contract.pdf"), "/Volumes/ParaAir/[path]")

        // In the commands' JSON: setup-status names the mount points, including one outside /Volumes.
        let setup = Data("""
        {"contractVersion":1,"app":{"installed":true,"path":"/Applications/ParaAir.app","running":true},
         "extension":{"state":"enabled","otherCopies":["/Volumes/ParaAir Cloud/Backups/Q3 Board Deck/ParaAir.app"]},
         "accounts":[],"profiles":[{"profile":"Team","stateDirectory":"/Users/thomas/Library/Application Support/StreamDrive","backend":"paraairCloud",
                                    "mountPoint":"/Users/thomas/Drives/Team Space","mounted":true,"healthy":true,"conflictCopies":false,"knownToApp":true}]}
        """.utf8)
        let text = SupportDiagnostics.text(.init(appVersion: "0.1.0 alpha 11 (72)", clientHeader: "mac/0.1.72", system: "Version 27.3",
                                                 createdAt: Date(timeIntervalSince1970: 0), setupStatus: .json(setup), drive: nil,
                                                 logs: .lines(["mount error: open failed /Users/thomas/Drives/Team Space/Q3 Board Deck.pdf"]),
                                                 accountEmails: [], home: home, mountPoints: ["/Volumes/ParaAir Cloud"]))
        for removed in ["Board Deck", "Backups"] { XCTAssertFalse(text.contains(removed), "removes \(removed)\n\(text)") }
        for kept in ["\"/Volumes/ParaAir Cloud/[path]\"", "\"mountPoint\" : \"~/Drives/Team Space\"", "open failed ~/Drives/Team Space/[path]"] {
            XCTAssertTrue(text.contains(kept), "shows \(kept)\n\(text)")
        }
    }

    /// A drive can be mounted outside /Volumes. Without setup-status nothing says where, so a log line naming a file in
    /// it can't be cleaned: the log lines are left out then, and kept once setup-status reports the mount points.
    func testDiagnosticsLeaveOutLogLinesWhenMountPointsAreUnknown() {
        let line = "mount error: open failed /Users/thomas/Drives/Team Space/Q3 Board Deck.pdf"
        func text(_ setup: SupportDiagnostics.Part, logs: SupportDiagnostics.Part = .lines([line])) -> String {
            SupportDiagnostics.text(.init(appVersion: "0.1.0 alpha 11 (72)", clientHeader: "mac/0.1.72", system: "Version 27.3",
                                          createdAt: Date(timeIntervalSince1970: 0), setupStatus: setup, drive: nil, logs: logs,
                                          accountEmails: [], home: home, mountPoints: ["/Volumes/ParaAir Cloud"]))
        }
        let failed = Data(#"{"error":"Couldn’t read the app’s folders","exitCode":1,"code":"failed"}"#.utf8)
        for setup in [SupportDiagnostics.Part.unavailable("This build has no paraair helper, so setup-status couldn’t run."), .json(failed),
                      .json(Data("not json".utf8))] {
            let copied = text(setup)
            XCTAssertFalse(copied.contains("Board Deck") || copied.contains("mount error"), "leaves the lines out\n\(copied)")
            XCTAssertTrue(copied.contains(SupportDiagnostics.logsWithheld), "says why\n\(copied)")
        }
        XCTAssertTrue(text(.unavailable("No helper."), logs: .unavailable("This app’s log couldn’t be read.")).contains("This app’s log couldn’t be read."),
                      "a reason the log couldn't be read is still shown")
        let listed = Data(#"{"contractVersion":1,"profiles":[{"profile":"Team","mountPoint":"/Users/thomas/Drives/Team Space","mounted":true}]}"#.utf8)
        let kept = text(.json(listed))
        XCTAssertTrue(kept.contains("mount error: open failed ~/Drives/Team Space/[path]") && !kept.contains("Board Deck"), kept)
        let none = text(.json(Data(#"{"contractVersion":1,"profiles":[]}"#.utf8)), logs: .lines(["open failed /Volumes/Work/Q3 Board Deck.pdf"]))
        XCTAssertTrue(none.contains("open failed /Volumes/Work/[path]"), "no drives listed: the lines stay, cleaned\n\(none)")
    }

    /// Of the commands' JSON only what the CLI contract documents is copied: a failing command's code and exit status
    /// without its message, and no field added later.
    func testDiagnosticsKeepOnlyDocumentedFields() {
        let failed = Data(#"{"error":"Couldn’t open “/Volumes/ParaAir Cloud/Acme/cut.mov”","exitCode":1,"code":"failed"}"#.utf8)
        let future = Data("""
        {"contractVersion":2,"lastOpened":"Q3 Board Deck.pdf","app":{"installed":true,"recentFile":"Acme contract.pdf"},
         "extension":{"state":"enabled","otherCopies":[],"note":{"by":"Lena"}},"accounts":[],
         "profiles":[{"profile":"Team","mounted":true,"healthy":["Acme"],"lastPath":"/Clients/Acme/cut.mov"}]}
        """.utf8)
        let text = SupportDiagnostics.text(.init(appVersion: "0.1.0 alpha 11 (72)", clientHeader: "mac/0.1.72", system: "Version 27.3",
                                                 createdAt: Date(timeIntervalSince1970: 0), setupStatus: .json(future),
                                                 drive: ("Team", .json(failed)), logs: .lines([]), accountEmails: [], home: home))
        for removed in ["Acme", "cut.mov", "Board Deck", "Lena", "lastOpened", "recentFile", "lastPath", "\"note\""] {
            XCTAssertFalse(text.contains(removed), "removes \(removed)\n\(text)")
        }
        for kept in ["\"code\" : \"failed\"", "\"exitCode\" : 1", "\"error\" : \"[removed]\"", "\"contractVersion\" : 2",
                     "\"profile\" : \"Team\"", "\"healthy\" : \"[removed]\"", "\"installed\" : true"] {
            XCTAssertTrue(text.contains(kept), "shows \(kept)\n\(text)")
        }
    }

    func testDiagnosticsRedactSecretsInEveryForm() {
        let scrubber = SupportDiagnostics.Scrubber(allowedEmails: ["owner@example.com"], home: home)
        let lines = [
            "aws_secret_access_key=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY&x=1", "AWS_SESSION_TOKEN=FwoGZXIvYXdzEBYaDHqa0AP",
            "session_token=FwoGZXIvYXdzEBYaDHqa0AQ", "api_key=sk-abc123def456", "apikey=abc123def456ghi", "X-Api-Key=abc123def789",
            "key AKIAIOSFODNN7EXAMPLE in use", #"{"SecretAccessKey": "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY2"}"#,
            "SecretAccessKey: wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY3", "SessionToken: FwoGZXIvYXdzEBYaDHqa0AR",
            "q=x%20pcs_secretsecret1&r=1", "body=%22pca_secretsecret2%22", "invite=lena%40studio.example", "next=%2522pcr_secretsecret3%2522",
            "callback?code=12345678&state=s1", "code=AbC123xyz",
        ]
        let text = lines.map(scrubber.scrub).joined(separator: "\n")
        for removed in ["wJalr", "FwoGZ", "abc123", "sk-abc", "AKIAIOSFODNN7EXAMPLE", "secretsecret", "lena", "studio.example", "12345678", "AbC123xyz"] {
            XCTAssertFalse(text.contains(removed), "removes \(removed)\n\(text)")
        }
        for kept in ["aws_secret_access_key=[redacted]&x=1", "AWS_SESSION_TOKEN=[redacted]", "api_key=[redacted]", "apikey=[redacted]",
                     "key [key] in use", #""SecretAccessKey": "[redacted]""#, "q=x [token]&r=1", "invite=[email]", "code=[redacted]&state=s1"] {
            XCTAssertTrue(text.contains(kept), "shows \(kept)\n\(text)")
        }
        // What support needs stays: short error codes, the account's own address, and words that only end like a secret's.
        XCTAssertEqual(scrubber.scrub("domain=NSCocoaErrorDomain code=-1 Code=516 owner@example.com"),
                       "domain=NSCocoaErrorDomain code=-1 Code=516 owner@example.com")
        // The home folder at the end of a line, or before punctuation, but not a folder whose name only starts with it.
        XCTAssertEqual(scrubber.scrub("install error: moved to /Users/thomas"), "install error: moved to ~")
        XCTAssertEqual(scrubber.scrub("moved to /Users/thomas."), "moved to ~.")
        XCTAssertEqual(scrubber.scrub("\"/Users/thomas\", /Users/thomas/Downloads"), "\"~\", ~/Downloads")
        XCTAssertEqual(scrubber.scrub("/Users/thomasina and /Users/thomas.old"), "/Users/thomasina and /Users/thomas.old")
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
