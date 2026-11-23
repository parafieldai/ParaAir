import Foundation

/// What a ParaAir Cloud failure means to a caller that reports a stable outcome, such as the CLI's exit codes: the
/// user has to sign in, their role or workspace doesn't allow the action, or the drive isn't available to them.
/// Read from the fixed messages this module puts on `DriveError` (`ParaAirCloudErrorCode.message` and the session's
/// signed-out error), never from the service's own text; a request id may follow the message.
public enum ParaAirCloudOutcome: String, Sendable, CaseIterable {
    case notSignedIn = "not_signed_in"
    case forbidden
    case driveNotFound = "drive_not_found"

    /// The session's error when no usable sign-in exists (ParaAirCloudSession).
    static let signInMessage = "Sign in to ParaAir Cloud"

    public static func of(_ error: Error) -> ParaAirCloudOutcome? {
        guard let error = error as? DriveError else { return nil }
        let message = error.message
        func starts(_ code: ParaAirCloudErrorCode) -> Bool { message.hasPrefix(code.message) }
        if message.hasPrefix(signInMessage) || starts(.unauthorized) || starts(.insufficientScope) { return .notSignedIn }
        if starts(.forbidden) || starts(.suspended) { return .forbidden }
        if starts(.driveNotFound) || starts(.workspaceNotFound) { return .driveNotFound }
        return nil
    }
}
