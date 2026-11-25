import CoreData
import Foundation

/// A list-query lower bound frozen at the first attempt of a run that may
/// take several attempts to finish (initial sync, history recovery).
///
/// Recomputing the bound on every attempt lets it slide forward: the
/// initial-sync cap moves with the clock, and recovery's install-branch bound
/// moves with the newest stored row, which the interrupted attempt itself
/// advanced (pages are saved newest-first). Anything the earlier attempt
/// failed on below the new bound would then be left behind by an advancing
/// cursor.
struct SyncWindowCheckpoint: Equatable, Sendable {
    static let initialSyncKind = "initialSyncWindow.v1"
    static let historyRecoveryKind = "historyRecoveryWindow.v1"

    let accountEmail: String
    let windowStart: TimeInterval
    /// How far the run inside this window had listed when it stopped; nil
    /// before its first page, after a listing that ended held, and in rows
    /// an earlier build wrote.
    var progress: PagedSyncProgress?
}

/// Reads and stages the model-v3 `SyncCheckpoint` row that freezes a run's
/// window. The caller owns the context save; this store never saves.
///
/// The freeze is staged before the run's first page and commits with that
/// page's save, which is the point: it must outlive an attempt that dies
/// part-way. The clear is staged only into the save that advances the
/// cursor, so a held or interrupted run resumes with the same bound.
///
/// The same row carries the run's page progress (`PagedSyncProgress`, step 8),
/// staged by each page's completion into that page's save. A held completion
/// stages the window again without it (the retry lists the window again from
/// its first page, its failures now in the ledger), and the advancing save
/// clears the row.
///
/// `pendingMessageIdsJSON` is the kind-discriminated payload slot in the
/// immutable v3 schema; `startHistoryId` and `pageToken` are always nil, so
/// the page token rides in the payload too. A payload without progress
/// (version 1 as written before step 8) still decodes: the field is optional.
struct SyncWindowCheckpointStore {
    private struct Payload: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let windowStart: TimeInterval
        let progress: PagedSyncProgress?
    }

    static let initialSync = SyncWindowCheckpointStore(kind: SyncWindowCheckpoint.initialSyncKind)
    static let historyRecovery = SyncWindowCheckpointStore(kind: SyncWindowCheckpoint.historyRecoveryKind)

    private let kind: String

    init(kind: String) {
        self.kind = kind
    }

    /// Returns the frozen window for this account, or nil when none was
    /// frozen. Rows for another account or with an unreadable payload are
    /// ignored here and replaced by the next `stageFreeze`.
    func load(
        accountEmail: String,
        in context: NSManagedObjectContext
    ) async throws -> SyncWindowCheckpoint? {
        let kind = self.kind
        return try await context.perform {
            for row in try Self.fetchRows(kind: kind, in: context) {
                guard row.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame,
                      row.startHistoryId == nil,
                      row.pageToken == nil,
                      let payload = Self.decodePayload(from: row) else {
                    continue
                }
                return SyncWindowCheckpoint(
                    accountEmail: row.accountEmail,
                    windowStart: payload.windowStart,
                    progress: payload.progress
                )
            }
            return nil
        }
    }

    /// Stages exactly one row of this kind carrying `windowStart` and
    /// `progress`; nil progress drops any progress the row held.
    func stageFreeze(
        windowStart: TimeInterval,
        progress: PagedSyncProgress? = nil,
        accountEmail: String,
        in context: NSManagedObjectContext
    ) async throws {
        let payloadData = try JSONEncoder().encode(
            Payload(version: Payload.currentVersion, windowStart: windowStart, progress: progress)
        )
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        let kind = self.kind
        try await context.perform {
            let rows = try Self.fetchRows(kind: kind, in: context)
            let now = Date()
            let checkpoint: SyncCheckpoint
            if let existing = rows.first {
                checkpoint = existing
            } else {
                checkpoint = SyncCheckpoint(context: context)
                checkpoint.id = UUID()
                checkpoint.kind = kind
                checkpoint.createdAt = now
            }
            checkpoint.accountEmail = accountEmail
            checkpoint.startHistoryId = nil
            checkpoint.pageToken = nil
            checkpoint.pendingMessageIdsJSON = payloadJSON
            checkpoint.updatedAt = now
            for row in rows where row.objectID != checkpoint.objectID {
                context.delete(row)
            }
        }
    }

    /// Stages deletion of every row of this kind.
    func stageClear(in context: NSManagedObjectContext) async throws {
        let kind = self.kind
        try await context.perform {
            try Self.fetchRows(kind: kind, in: context).forEach(context.delete)
        }
    }

    private static func decodePayload(from row: SyncCheckpoint) -> Payload? {
        guard let payloadJSON = row.pendingMessageIdsJSON,
              let payloadData = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.version == Payload.currentVersion,
              payload.windowStart.isFinite else {
            return nil
        }
        return payload
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
