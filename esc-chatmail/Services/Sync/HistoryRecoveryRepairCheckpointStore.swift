import CoreData
import Foundation

/// What a history recovery still owes the rows it did not visit
/// (`HistoryRecoveryRepair`): the newest internal date, exclusive, of the rows not yet
/// compared with Gmail. The repair walks the stored rows from there toward the oldest.
struct HistoryRecoveryRepairCheckpoint: Equatable, Sendable {
    static let kind = "historyRecoveryRepair.v1"

    let accountEmail: String
    /// Rows with an internal date before this are still owed a comparison. Kept as the
    /// `Date` itself, never seconds since 1970: a row's stored date converted to those and
    /// back can come out a hair later, and a bound that does so takes the row it was cut
    /// at into the next batch again, for ever.
    let upperBound: Date
    /// Consecutive runs that left `upperBound` where it was
    /// (`HistoryRecoveryRepairPolicy.progressAfterStall`).
    var runsWithoutProgress: Int = 0
}

/// Reads and stages the model-v3 `SyncCheckpoint` row that records a history
/// recovery's owed repair. The caller owns the context save; this store never saves.
///
/// Staged into the save that advances recovery's cursor, and into no other: a held
/// recovery has not moved the cursor past anything yet. Its progress and its clear are
/// staged into the incremental run's final save, beside the repairs they record, so
/// the repairs and the record of them commit or die together.
///
/// `pendingMessageIdsJSON` is the kind-discriminated payload slot in the immutable v3
/// schema; `startHistoryId` and `pageToken` are always nil.
struct HistoryRecoveryRepairCheckpointStore {
    private struct Payload: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        /// Seconds since the reference date, the representation Core Data stores.
        let upperBoundSinceReferenceDate: TimeInterval
        let runsWithoutProgress: Int?
    }

    init() {}

    /// The owed repair for this account, or nil. A row for another account or with an
    /// unreadable payload is ignored and replaced by the next `stageOwed`.
    func load(
        accountEmail: String,
        in context: NSManagedObjectContext
    ) async throws -> HistoryRecoveryRepairCheckpoint? {
        try await context.perform {
            for row in try Self.fetchRows(in: context) {
                guard row.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame,
                      row.startHistoryId == nil,
                      row.pageToken == nil,
                      let payload = Self.decodePayload(from: row) else {
                    continue
                }
                return HistoryRecoveryRepairCheckpoint(
                    accountEmail: row.accountEmail,
                    upperBound: Date(timeIntervalSinceReferenceDate: payload.upperBoundSinceReferenceDate),
                    runsWithoutProgress: max(0, payload.runsWithoutProgress ?? 0)
                )
            }
            return nil
        }
    }

    /// Stages exactly one row owing a repair of every row older than `upperBound`.
    func stageOwed(
        upperBound: Date,
        runsWithoutProgress: Int = 0,
        accountEmail: String,
        in context: NSManagedObjectContext
    ) async throws {
        let payloadData = try JSONEncoder().encode(
            Payload(
                version: Payload.currentVersion,
                upperBoundSinceReferenceDate: upperBound.timeIntervalSinceReferenceDate,
                runsWithoutProgress: runsWithoutProgress
            )
        )
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try await context.perform {
            let rows = try Self.fetchRows(in: context)
            let now = Date()
            let checkpoint: SyncCheckpoint
            if let existing = rows.first {
                checkpoint = existing
            } else {
                checkpoint = SyncCheckpoint(context: context)
                checkpoint.id = UUID()
                checkpoint.kind = HistoryRecoveryRepairCheckpoint.kind
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

    func stageClear(in context: NSManagedObjectContext) async throws {
        try await context.perform {
            try Self.fetchRows(in: context).forEach(context.delete)
        }
    }

    private static func decodePayload(from row: SyncCheckpoint) -> Payload? {
        guard let payloadJSON = row.pendingMessageIdsJSON,
              let payloadData = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.version == Payload.currentVersion,
              payload.upperBoundSinceReferenceDate.isFinite else {
            return nil
        }
        return payload
    }

    private static func fetchRows(in context: NSManagedObjectContext) throws -> [SyncCheckpoint] {
        let request = SyncCheckpoint.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %@", HistoryRecoveryRepairCheckpoint.kind)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(request)
    }
}
