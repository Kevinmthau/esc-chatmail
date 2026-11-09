import Foundation

/// The macOS sandbox tripwire: applies `SandboxTripwirePolicy` to this process
/// at every cleanup that deletes or sweeps one of the app's storage folders.
///
/// Each guarded function calls it first, under `#if os(macOS)`, before it
/// touches the disk. A refusal logs an error and throws
/// `SandboxTripwireError`:
/// - Throwing callers propagate it. Account removal then reports a failed
///   cleanup and keeps its durable reset marker instead of claiming the files
///   are gone, so an unsandboxed build can't sign in again rather than
///   deleting the user's folders.
/// - Non-throwing callers use `permitsDestructiveCleanup(_:environment:)` and
///   return before deleting or recreating anything.
///
/// `SandboxTripwireTests` checks that every `Operation` is wired into exactly
/// the function its raw value names, because the iOS test target can't run
/// the macOS branches.
enum SandboxTripwire {
    /// The cleanups the tripwire guards. Each raw value names the guarded
    /// function, for the refusal's log line and error.
    enum Operation: String, CaseIterable, Sendable {
        /// Fresh-install cleanup of `Documents/Attachments`, `Documents/Messages`,
        /// `Application Support/Attachments`, `Application Support/Previews`
        /// and the legacy attachment cache.
        case freshInstallAttachmentFiles = "FreshInstallHandler.clearAttachmentFiles"
        /// Account-removal cleanup of `Application Support/Attachments`,
        /// `Application Support/Previews` and the legacy attachment cache.
        case accountRemovalAttachmentFiles = "AuthSession.deleteAttachmentFilesFromDisk"
        /// Account-removal cleanup of everything in `Documents/Messages`. It
        /// runs before `accountRemovalAttachmentFiles` in every account-removal
        /// cleanup, so guarding that one alone would still empty the folder.
        case accountRemovalMessageBodies = "HTMLContentHandler.deleteAllHTMLFromClosedAccount"
        /// The maintenance sweep of files in `Documents/Messages` that no
        /// message names.
        case orphanedMessageBodySweep = "HTMLContentHandler.cleanupOrphanedFiles"
        /// The maintenance sweep of files under `Application Support/Attachments`
        /// and `Application Support/Previews` that no attachment names.
        case orphanedAttachmentFileSweep = "AttachmentDownloader.cleanupOrphanedFiles"

        /// The category of the subsystem that owns the files.
        var logCategory: LogCategory {
            switch self {
            case .freshInstallAttachmentFiles, .accountRemovalAttachmentFiles, .orphanedAttachmentFileSweep:
                return .attachment
            case .accountRemovalMessageBodies, .orphanedMessageBodySweep:
                return .general
            }
        }
    }

    /// Returns when `operation` may delete files, and otherwise logs the
    /// refusal and throws `SandboxTripwireError.refusedOutsideAppSandbox`.
    static func ensureDestructiveCleanupPermitted(
        _ operation: Operation,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        switch SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment) {
        case .permitted:
            return
        case .refusedOutsideAppSandbox:
            Log.error(
                "Sandbox tripwire: \(operation.rawValue) refused to delete files. This process has no \(SandboxTripwirePolicy.containerIdentifierEnvironmentKey), so it is not in an App Sandbox container and its Documents and Application Support folders are the user's own. Nothing was deleted.",
                category: operation.logCategory
            )
            throw SandboxTripwireError.refusedOutsideAppSandbox(operation)
        }
    }

    /// `ensureDestructiveCleanupPermitted(_:environment:)` for callers that
    /// can't throw: `false` means the refusal is logged and the caller must
    /// return without deleting anything.
    static func permitsDestructiveCleanup(
        _ operation: Operation,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        do {
            try ensureDestructiveCleanupPermitted(operation, environment: environment)
            return true
        } catch {
            return false
        }
    }
}
