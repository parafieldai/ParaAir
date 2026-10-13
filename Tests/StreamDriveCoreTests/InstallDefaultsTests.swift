import XCTest
@testable import StreamDriveCore

final class InstallDefaultsTests: XCTestCase {
    private let home = "/Users/maya"

    private func classify(_ path: String, readOnly: Bool = false) -> InstallLocation {
        InstallLocation.classify(bundlePath: path, homeDirectory: home, volumeIsReadOnly: readOnly)
    }

    // MARK: Location

    func testTranslocatedDownloadsAndDiskImagesAreClassifiedFirst() {
        let translocated = "/private/var/folders/x1/abc/T/AppTranslocation/2C3D4E5F-0000-4000-8000-000000000000/d/ParaAir.app"
        XCTAssertEqual(classify(translocated), .translocated)
        // The translocation mount is read-only too; translocation still names it.
        XCTAssertEqual(classify(translocated, readOnly: true), .translocated)
        XCTAssertEqual(classify("/Volumes/ParaAir/ParaAir.app", readOnly: true), .readOnlyVolume)
    }

    func testApplicationsFoldersAreRecognized() {
        XCTAssertEqual(classify("/Applications/ParaAir.app"), .applications)
        XCTAssertEqual(classify("/Applications/ParaAir.app/"), .applications)
        XCTAssertEqual(classify("/Applications/Utilities/ParaAir.app"), .applications)
        XCTAssertEqual(classify("/Users/maya/Applications/ParaAir.app"), .applications)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Users/maya/Applications/ParaAir.app", homeDirectory: "/Users/maya/",
                                                volumeIsReadOnly: false), .applications)
    }

    func testOtherWritableFoldersAreElsewhere() {
        XCTAssertEqual(classify("/Users/maya/Code/ParaAir/.build/xcode/Build/Products/Release/ParaAir.app"), .elsewhere)
        XCTAssertEqual(classify("/Users/maya/Downloads/ParaAir.app"), .elsewhere)
        XCTAssertEqual(classify("/Users/maya/Desktop/ParaAir.app"), .elsewhere)
        // A folder that only starts with the same letters is not an Applications folder.
        XCTAssertEqual(classify("/ApplicationsOld/ParaAir.app"), .elsewhere)
        XCTAssertEqual(classify("/Users/other/Applications/ParaAir.app"), .elsewhere)
    }

    func testOnlyTranslocatedAndReadOnlyCopiesMove() {
        XCTAssertTrue(InstallLocation.translocated.shouldMove)
        XCTAssertTrue(InstallLocation.readOnlyVolume.shouldMove)
        XCTAssertFalse(InstallLocation.applications.shouldMove)
        XCTAssertFalse(InstallLocation.elsewhere.shouldMove)
    }

    // MARK: Destination

    func testDestinationPrefersSystemApplicationsWhenWritable() {
        XCTAssertEqual(InstallDestination.path(systemApplicationsWritable: true, homeDirectory: home), "/Applications/ParaAir.app")
        XCTAssertEqual(InstallDestination.path(systemApplicationsWritable: false, homeDirectory: home), "/Users/maya/Applications/ParaAir.app")
        XCTAssertEqual(InstallDestination.folder(systemApplicationsWritable: false, homeDirectory: "/Users/maya/"), "/Users/maya/Applications")
    }

    // MARK: Versions

    func testBuildNumberDecidesThenMarketingVersion() {
        let current = BundleVersion(build: "7", marketing: "0.2.0")
        XCTAssertTrue(BundleVersion(build: "8", marketing: "0.1.0").isNewer(than: current))
        XCTAssertFalse(BundleVersion(build: "6", marketing: "9.0.0").isNewer(than: current))
        XCTAssertTrue(BundleVersion(build: "7", marketing: "0.2.1").isNewer(than: current))
        XCTAssertFalse(BundleVersion(build: "7", marketing: "0.2.0").isNewer(than: current), "the same version is not newer")
        XCTAssertFalse(BundleVersion(build: "7", marketing: "0.1.9").isNewer(than: current))
    }

    func testVersionComponentsCompareNumerically() {
        XCTAssertTrue(BundleVersion(build: "1.10", marketing: nil).isNewer(than: BundleVersion(build: "1.9", marketing: nil)))
        XCTAssertEqual(BundleVersion.compare("1.0", "1"), .orderedSame)
        XCTAssertEqual(BundleVersion.compare("2b3", "2"), .orderedSame)
        XCTAssertEqual(BundleVersion.compare("10", "9"), .orderedDescending)
        XCTAssertEqual(BundleVersion.compare(" ", nil), .orderedSame, "a blank value counts as missing")
    }

    func testMissingVersionsAreOlder() {
        let current = BundleVersion(build: "1", marketing: "0.1.0")
        XCTAssertFalse(BundleVersion(build: nil, marketing: nil).isNewer(than: current))
        XCTAssertTrue(current.isNewer(than: BundleVersion(build: nil, marketing: nil)))
        XCTAssertEqual(BundleVersion(infoDictionary: ["CFBundleVersion": "3", "CFBundleShortVersionString": "0.3.0"]),
                       BundleVersion(build: "3", marketing: "0.3.0"))
        XCTAssertEqual(BundleVersion(infoDictionary: [:]), BundleVersion(build: nil, marketing: nil))
    }

    // MARK: Plan

    func testPlanStaysPutUnlessTheCopyMustMove() {
        let version = BundleVersion(build: "1", marketing: "0.1.0")
        let older = InstalledCopy(version: BundleVersion(build: "0", marketing: "0.0.9"), sameIdentifier: true, running: false)
        XCTAssertEqual(InstallAction.plan(location: .elsewhere, installed: nil, running: version), .stay)
        XCTAssertEqual(InstallAction.plan(location: .elsewhere, installed: older, running: version), .stay)
        XCTAssertEqual(InstallAction.plan(location: .applications, installed: older, running: version), .stay)
    }

    func testPlanInstallsReplacesOrOpensTheInstalledCopy() {
        let version = BundleVersion(build: "5", marketing: "0.5.0")
        func copy(_ build: String, same: Bool = true, running: Bool = false) -> InstalledCopy {
            InstalledCopy(version: BundleVersion(build: build, marketing: "0.\(build).0"), sameIdentifier: same, running: running)
        }
        for location in [InstallLocation.translocated, .readOnlyVolume] {
            XCTAssertEqual(InstallAction.plan(location: location, installed: nil, running: version), .install(replacingExisting: false))
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("4"), running: version), .install(replacingExisting: true))
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("5"), running: version), .install(replacingExisting: true),
                           "the same version is replaced")
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("6"), running: version), .openInstalled)
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("4", running: true), running: version), .askToReplaceRunning,
                           "an older open copy is offered the update, never silently kept")
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("5", running: true), running: version), .openInstalled,
                           "the same version already open is switched to")
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("6", running: true), running: version), .openInstalled,
                           "a newer open copy is switched to")
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("4", same: false, running: true), running: version),
                           .askToMoveManually, "another app named ParaAir.app is never quit")
            XCTAssertEqual(InstallAction.plan(location: location, installed: copy("9", same: false), running: version), .askToMoveManually,
                           "another app named ParaAir.app is never replaced or opened")
        }
    }

    func testOlderRunningCopyUsesTheMarketingVersionThenTheBuild() {
        let installed = InstalledCopy(version: BundleVersion(build: "5", marketing: "0.5.0"), sameIdentifier: true, running: true)
        // CFBundleVersion decides even when the marketing versions match.
        XCTAssertEqual(InstallAction.plan(location: .translocated, installed: installed,
                                          running: BundleVersion(build: "6", marketing: "0.5.0")), .askToReplaceRunning)
        XCTAssertEqual(InstallAction.plan(location: .translocated, installed: installed,
                                          running: BundleVersion(build: "5", marketing: "0.5.1")), .askToReplaceRunning,
                       "CFBundleShortVersionString breaks a tie")
        XCTAssertEqual(InstallAction.plan(location: .elsewhere, installed: installed,
                                          running: BundleVersion(build: "9", marketing: "0.9.0")), .stay,
                       "a developer build never asks")
    }

    func testReplaceRunningPromptNamesBothVersions() {
        let old = BundleVersion(build: "5", marketing: "0.5.0")
        XCTAssertEqual(InstallPrompt.replaceRunning(installed: old, running: BundleVersion(build: "7", marketing: "0.7.0")),
                       "ParaAir 0.5.0 is open. Quit it and install 0.7.0?")
        XCTAssertEqual(InstallPrompt.replaceRunning(installed: old, running: BundleVersion(build: "6", marketing: "0.5.0")),
                       "ParaAir 0.5.0 (5) is open. Quit it and install 0.5.0 (6)?", "matching marketing versions add the build")
        XCTAssertEqual(InstallPrompt.replaceRunning(installed: BundleVersion(build: nil, marketing: nil),
                                                    running: BundleVersion(build: "7", marketing: "0.7.0")),
                       "An older ParaAir is open. Quit it and install ParaAir 0.7.0?")
        XCTAssertEqual(InstallPrompt.replaceRunning(installed: old, running: BundleVersion(build: nil, marketing: nil)),
                       "ParaAir 0.5.0 is open. Quit it and install this version?")
        XCTAssertEqual(BundleVersion(build: "3", marketing: " ").label(distinctFrom: old), "build 3")
        XCTAssertFalse(InstallPrompt.replaceRunning(installed: old, running: BundleVersion(build: "7", marketing: "0.7.0")).contains("\u{2014}"))
    }

    // MARK: Open at login

    func testLoginItemDefaultRegistersOnceFromApplicationsOnly() {
        XCTAssertEqual(LoginItemDefault.decide(location: .applications, alreadyApplied: false, status: .notRegistered), .register)
        XCTAssertEqual(LoginItemDefault.decide(location: .applications, alreadyApplied: false, status: .notFound), .register)
        XCTAssertEqual(LoginItemDefault.decide(location: .applications, alreadyApplied: false, status: .enabled), .recordOnly)
        XCTAssertEqual(LoginItemDefault.decide(location: .applications, alreadyApplied: false, status: .requiresApproval), .recordOnly)
    }

    func testLoginItemDefaultNeverOverridesOrRegistersDeveloperBuilds() {
        for status in [LoginItemStatus.enabled, .notRegistered, .requiresApproval, .notFound] {
            XCTAssertEqual(LoginItemDefault.decide(location: .applications, alreadyApplied: true, status: status), .skip,
                           "turned off after the default was applied stays off")
            for location in [InstallLocation.elsewhere, .translocated, .readOnlyVolume] {
                XCTAssertEqual(LoginItemDefault.decide(location: location, alreadyApplied: false, status: status), .skip)
            }
        }
        XCTAssertEqual(LoginItemDefault.appliedKey, "loginItemDefaultApplied")
    }
}
