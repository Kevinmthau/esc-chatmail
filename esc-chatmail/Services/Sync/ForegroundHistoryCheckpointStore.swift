import CoreData
import Foundation

/// Durable position for the next bounded foreground History API slice.
/// A row always carries a real Gmail continuation token; absence of a row
/// means the executor starts from the Account's still-frozen history cursor.
struct ForegroundHistoryCheckpoint: Equatable, Sendable {
    static let kind = "foregroundHistory.v1"

    let accountEmail: String
    let startHistoryId: String
    let pageToken: String
}

enum ForegroundHistoryCheckpointStoreError: LocalizedError, Equatable {
    case emptyPageToken

    var errorDescription: String? {
        switch self {
        case .emptyPageToken:
            return "A Gmail history continuation token cannot be empty."
        }
    }
}

/// Stages model-v3 `SyncCheckpoint` mutations in the caller's sync context.
/// Nothing here saves: page effects, failure state, ledger transitions, and
/// continuation movement therefore succeed or fail together in the
/// orchestrator's existing final save.
struct ForegroundHistoryCheckpointStore {
    private let kind: String

    init(kind: String = ForegroundHistoryCheckpoint.kind) {
        self.kind = kind
    }

    /// Returns the newest compatible checkpoint. Stale, malformed, or
    /// duplicate rows are staged for deletion and the caller safely replays
    /// from its still-frozen Account cursor.
    ///
    /// Compatibility is checked against the Account row in this same context,
    /// not only the snapshot read earlier by MessagePersister. The production
    /// orchestrator separately verifies the authenticated account as the third
    /// leg of the single-account invariant.
    func loadCompatible(
        accountEmail: String,
        startHistoryId: String,
        in context: NSManagedObjectContext
    ) async throws -> ForegroundHistoryCheckpoint? {
        let kind = self.kind
        return try await context.perform {
            let rows = try Self.fetchRows(kind: kind, in: context)
            guard !rows.isEmpty else { return nil }

            let accountRequest = Account.fetchRequest()
            let accounts = try context.fetch(accountRequest)
            let accountMatches = accounts.contains { account in
                account.email.caseInsensitiveCompare(accountEmail) == .orderedSame &&
                    account.historyId == startHistoryId
            }
            guard accountMatches else {
                rows.forEach(context.delete)
                return nil
            }

            var selected: (row: SyncCheckpoint, snapshot: ForegroundHistoryCheckpoint)?
            for row in rows {
                guard selected == nil,
                      row.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame,
                      row.startHistoryId == startHistoryId,
                      let snapshot = Self.decodeSnapshot(from: row) else {
                    continue
                }
                selected = (row, snapshot)
            }

            guard let selected else {
                rows.forEach(context.delete)
                return nil
            }

            for row in rows where row.objectID != selected.row.objectID {
                context.delete(row)
            }
            return selected.snapshot
        }
    }

    /// Stages the exact position to retry or continue from. Gmail page tokens
    /// are opaque and are persisted byte-for-byte; trimming is used only to
    /// reject an empty/whitespace-only server value.
    func stageProgress(
        accountEmail: String,
        startHistoryId: String,
        pageToken: String,
        in context: NSManagedObjectContext
    ) async throws {
        if pageToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ForegroundHistoryCheckpointStoreError.emptyPageToken
        }
        let kind = self.kind

        try await context.perform {
            let rows = try Self.fetchRows(kind: kind, in: context)
            let now = Date()
            let checkpoint: SyncCheckpoint
            if let existing = rows.first {
                checkpoint = existing
                for duplicate in rows.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                checkpoint = SyncCheckpoint(context: context)
                checkpoint.id = UUID()
                checkpoint.kind = kind
                checkpoint.createdAt = now
            }

            checkpoint.accountEmail = accountEmail
            checkpoint.startHistoryId = startHistoryId
            checkpoint.pageToken = pageToken
            // This executor checkpoints between fully processed slices, so it
            // never owns an unfinished message-ID payload. A non-nil payload
            // is rejected on load to avoid skipping work written by a future
            // or rolled-back executor format.
            checkpoint.pendingMessageIdsJSON = nil
            checkpoint.updatedAt = now
        }
    }

    func stageClear(in context: NSManagedObjectContext) async throws {
        let kind = self.kind
        try await context.perform {
            for checkpoint in try Self.fetchRows(kind: kind, in: context) {
                context.delete(checkpoint)
            }
        }
    }

    private static func decodeSnapshot(
        from row: SyncCheckpoint
    ) -> ForegroundHistoryCheckpoint? {
        guard let pageToken = row.pageToken,
              !pageToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              row.pendingMessageIdsJSON == nil,
              let startHistoryId = row.startHistoryId else {
            return nil
        }

        return ForegroundHistoryCheckpoint(
            accountEmail: row.accountEmail,
            startHistoryId: startHistoryId,
            pageToken: pageToken
        )
    }

    private static func fetchRows(
        kind: String,
        in context: NSManagedObjectContext
    ) throws -> [SyncCheckpoint] {
        let request = SyncCheckpoint.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %@", kind)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(request)
    }
}
