import Foundation

/// Why a cleanup that `SandboxTripwire` guards deleted nothing.
enum SandboxTripwireError: LocalizedError, Equatable {
    /// The process isn't in an App Sandbox container on macOS, so the folders
    /// the operation would delete are the user's own rather than the app's.
    case refusedOutsideAppSandbox(SandboxTripwire.Operation)

    var errorDescription: String? {
        switch self {
        case .refusedOutsideAppSandbox(let operation):
            return "\(operation.rawValue) refused to delete files outside the App Sandbox"
        }
    }
}
