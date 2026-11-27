import Foundation
import XCTest
import Darwin
@testable import StreamDriveCore

final class ParaAirCloudOutcomeTests: XCTestCase {
    private func serviceError(_ code: ParaAirCloudErrorCode) -> DriveError {
        let body = Data(#"{"error":{"code":"\#(code.rawValue)","message":"x","requestId":"req_01M83ABCDEFGHJKMNPQRSTVWXY"}}"#.utf8)
        return ParaAirCloudErrorMap.error(status: code.httpStatus, body: body, requestID: "req_01M83ABCDEFGHJKMNPQRSTVWXY", phase: .other)
    }

    func testServiceCodesMapToTheOutcomesWithOrWithoutARequestID() {
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.unauthorized)), .notSignedIn)
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.insufficientScope)), .notSignedIn)
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.forbidden)), .forbidden)
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.suspended)), .forbidden)
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.driveNotFound)), .driveNotFound)
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.workspaceNotFound)), .driveNotFound)
        // The session's own signed-out error, raised before any request.
        XCTAssertEqual(ParaAirCloudOutcome.of(DriveError(EACCES, "Sign in to ParaAir Cloud")), .notSignedIn)
        // 426 client_too_old, and the engine refusing a change while it holds.
        XCTAssertEqual(ParaAirCloudOutcome.of(serviceError(.clientTooOld)), .updateRequired)
        XCTAssertEqual(ParaAirCloudOutcome.of(DriveError(EROFS, Engine.updateRequiredMessage)), .updateRequired)
    }

    func testEverythingElseHasNoOutcome() {
        for code in ParaAirCloudErrorCode.allCases where ![.unauthorized, .insufficientScope, .forbidden, .suspended, .driveNotFound, .workspaceNotFound,
                                                            .clientTooOld].contains(code) {
            XCTAssertNil(ParaAirCloudOutcome.of(serviceError(code)), code.rawValue)
        }
        XCTAssertNil(ParaAirCloudOutcome.of(DriveError(EIO, "ParaAir Cloud is temporarily unavailable")))
        XCTAssertNil(ParaAirCloudOutcome.of(CocoaError(.fileNoSuchFile)))
    }
}
