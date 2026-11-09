import Foundation

/// Decides whether this process may delete the app's storage folders. This is
/// the decision half of the macOS sandbox tripwire (docs/mac-app-plan.md,
/// Phase 1 PR C); `SandboxTripwire` applies it.
///
/// The app finds its storage through `FileManager`'s user-domain directories:
/// `Documents/Messages`, `Documents/Attachments`, and `Attachments` and
/// `Previews` under Application Support. Fresh-install cleanup, account
/// removal and maintenance delete those folders or sweep their contents.
/// Inside the App Sandbox the user domain is the app's own container. In an
/// unsandboxed macOS process, such as a build whose signature lost its
/// entitlements, the same lookups return the user's real `~/Documents` and the
/// `~/Library/Application Support` that every app shares, so the cleanup would
/// delete files that aren't the app's.
///
/// Pure and platform-neutral so the decision is unit-tested on iOS. Only macOS
/// call sites consult it, under `#if os(macOS)`: every iOS app is sandboxed,
/// and the container identifier is a macOS convention.
enum SandboxTripwirePolicy {
    /// macOS sets this variable to the container's identifier in a process
    /// that runs in an App Sandbox container.
    static let containerIdentifierEnvironmentKey = "APP_SANDBOX_CONTAINER_ID"

    enum Verdict: Equatable, Sendable {
        /// The process runs in an App Sandbox container, so the folders resolve
        /// inside it and belong to this app.
        case permitted
        /// There is no sandbox container, so the folders are the user's own.
        /// Nothing may be deleted.
        case refusedOutsideAppSandbox
    }

    /// Permits destructive cleanup only when `environment` names an App Sandbox
    /// container. A missing or blank identifier refuses: when the evidence is
    /// unclear, keeping files is always safe and deleting them is not.
    static func destructiveCleanupVerdict(environment: [String: String]) -> Verdict {
        guard let containerIdentifier = environment[containerIdentifierEnvironmentKey],
              !containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refusedOutsideAppSandbox
        }
        return .permitted
    }
}
