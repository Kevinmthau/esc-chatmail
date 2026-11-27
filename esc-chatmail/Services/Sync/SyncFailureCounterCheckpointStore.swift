import CoreData
import Foundation

/// The durable, account-scoped consecutive-sync-failure count.
///
/// A zero-valued row is intentionally retained. Its presence is the durable
/// migration tombstone that prevents a stale legacy UserDefaults value from
/// being imported again after the counter has been reset.
struct SyncFailureCounterCheckpoint: Equatable, Sendable {
    static let kind = "syncFailureCounter.v1"

    let accountEmail: String
    let consecutiveFailureCount: Int
    /// When the last strike counted (`SyncFailureStrikePolicy`). Nil on a row
    /// an earlier build wrote, a repaired row, a legacy import and a reset
    /// counter, each of which makes the next failing run a strike.
    let lastStrikeAt: Date?

    var strikes: SyncFailureStrikes {
        SyncFailureStrikes(count: consecutiveFailureCount, lastStrikeAt: lastStrikeAt)
    }
}

enum SyncFailureCounterCheckpointStoreError: LocalizedError, Equatable {
    case invalidFailureCount(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFailureCount(let count):
            return "A sync failure counter cannot store a negative value (\(count))."
        }
    }
}

/// Reads and stages the model-v3 `SyncCheckpoint` row used by the sync failure
/// counter. The caller owns the context save; this store never saves or creates
/// a separate transaction.
///
/// `pendingMessageIdsJSON` is a kind-discriminated payload slot in the immutable
/// v3 schema. For `syncFailureCounter.v1` it contains a versioned counter object;
/// `startHistoryId` and `pageToken` are always nil.
///
/// `lastStrikeAt` was added to the payload after it shipped (architecture
/// review 2026-11, sync-engine#2), as an optional field under the same
/// version: a row of any other version is repaired to zero (`decodePayload`),
/// so a bump would have cleared every held count once, and an earlier build
/// ignores the key.
/// Absent, it decodes as nil.
struct SyncFailureCounterCheckpointStore {
    private struct Payload: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let consecutiveFailureCount: Int
        let lastStrikeAt: Date?
    }

    private let kind: String

    init(kind: String = SyncFailureCounterCheckpoint.kind) {
        self.kind = kind
    }

    /// Loads the compatible counter, or stages an initialized/repaired row in
    /// the supplied context and returns that staged value.
    ///
    /// A valid case-insensitive account match is authoritative even when a
    /// legacy value is supplied. Existing malformed or wrong-account rows are
    /// repaired to zero and never fall back to legacy state. Only true row
    /// absence may import a nonnegative legacy value, and only when a matching
    /// Account already exists in the persistent store (pending Account inserts
    /// do not establish migration provenance).
    func load(
        accountEmail: String,
        legacyConsecutiveFailureCount: Int? = nil,
        in context: NSManagedObjectContext
    ) async throws -> SyncFailureCounterCheckpoint {
        let kind = self.kind

        return try await context.perform {
            let rows = try Self.fetchRows(kind: kind, in: context)

            let compatible = rows.lazy.compactMap { row -> (SyncCheckpoint, Payload)? in
                guard Self.isCompatible(row, accountEmail: accountEmail),
                      let payload = Self.decodePayload(from: row) else {
                    return nil
                }
                return (row, payload)
            }.first
            if let (selected, payload) = compatible {
                Self.deleteDuplicates(except: selected, from: rows, in: context)
                return SyncFailureCounterCheckpoint(
                    accountEmail: selected.accountEmail,
                    consecutiveFailureCount: payload.consecutiveFailureCount,
                    lastStrikeAt: payload.lastStrikeAt
                )
            }

            if let reusable = rows.first(where: {
                $0.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame
            }) ?? rows.first {
                // Row presence means migration has already been attempted. A
                // malformed payload or account mismatch must fail safe to zero,
                // never resurrect an unrelated legacy UserDefaults count.
                try Self.apply(
                    count: 0,
                    lastStrikeAt: nil,
                    accountEmail: accountEmail,
                    to: reusable,
                    now: Date()
                )
                Self.deleteDuplicates(except: reusable, from: rows, in: context)
                return SyncFailureCounterCheckpoint(
                    accountEmail: accountEmail,
                    consecutiveFailureCount: 0,
                    lastStrikeAt: nil
                )
            }

            let mayImportLegacy = try Self.hasCommittedAccount(
                matching: accountEmail,
                in: context
            )
            let initialCount = mayImportLegacy
                ? Self.sanitizedLegacyCount(legacyConsecutiveFailureCount)
                : 0
            let now = Date()
            let checkpoint = SyncCheckpoint(context: context)
            checkpoint.id = UUID()
            checkpoint.kind = kind
            checkpoint.createdAt = now
            try Self.apply(
                count: initialCount,
                lastStrikeAt: nil,
                accountEmail: accountEmail,
                to: checkpoint,
                now: now
            )
            return SyncFailureCounterCheckpoint(
                accountEmail: accountEmail,
                consecutiveFailureCount: initialCount,
                lastStrikeAt: nil
            )
        }
    }

    /// Stages an exact counter value in the supplied context. Existing identity
    /// and creation time are preserved; unexpected duplicates are removed.
    ///
    /// A row that already holds exactly this value, alone, is left untouched
    /// (`alreadyHolds`). Every incremental run stages the counter, and
    /// restamping an unchanged row's `updatedAt` gave the sync context a change
    /// to save on a run that found nothing: a store commit and a
    /// persistent-history transaction every idle minute on the Mac
    /// (architecture review 2026-11, background-energy#4). The check is made
    /// before anything is assigned, because assigning an equal value still
    /// marks the row updated.
    ///
    /// - Parameter lastStrikeAt: When the last strike counted, which the
    ///   incremental slice path spaces the next one from. Nil (the default,
    ///   which initial sync and every reset to zero stage) makes the next
    ///   failing run a strike: the fail-safe direction, and the behavior of
    ///   every build before strikes were spaced.
    func stage(
        consecutiveFailureCount: Int,
        lastStrikeAt: Date? = nil,
        accountEmail: String,
        in context: NSManagedObjectContext
    ) async throws {
        guard consecutiveFailureCount >= 0 else {
            throw SyncFailureCounterCheckpointStoreError.invalidFailureCount(
                consecutiveFailureCount
            )
        }

        let kind = self.kind
        try await context.perform {
            let rows = try Self.fetchRows(kind: kind, in: context)
            if rows.count == 1,
               Self.alreadyHolds(
                   count: consecutiveFailureCount,
                   lastStrikeAt: lastStrikeAt,
                   accountEmail: accountEmail,
                   rows[0]
               ) {
                return
            }
            let now = Date()
            let checkpoint: SyncCheckpoint
            if let compatible = rows.first(where: {
                $0.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame
            }) {
                checkpoint = compatible
            } else if let existing = rows.first {
                checkpoint = existing
            } else {
                checkpoint = SyncCheckpoint(context: context)
                checkpoint.id = UUID()
                checkpoint.kind = kind
                checkpoint.createdAt = now
            }

            try Self.apply(
                count: consecutiveFailureCount,
                lastStrikeAt: lastStrikeAt,
                accountEmail: accountEmail,
                to: checkpoint,
                now: now
            )
            Self.deleteDuplicates(except: checkpoint, from: rows, in: context)
        }
    }

    /// Whether `row` already reads as what `apply` would write, `updatedAt`
    /// aside: the same account, spelled the same, no history position, and a
    /// current-version payload with this count and strike time. A payload that
    /// cannot be read, or a strike time that does not round-trip exactly, is
    /// written again: the cost of a wrong "no" is one save, of a wrong "yes" a
    /// lost count.
    private static func alreadyHolds(
        count: Int,
        lastStrikeAt: Date?,
        accountEmail: String,
        _ row: SyncCheckpoint
    ) -> Bool {
        row.accountEmail == accountEmail &&
            row.startHistoryId == nil &&
            row.pageToken == nil &&
            decodePayload(from: row) == Payload(
                version: Payload.currentVersion,
                consecutiveFailureCount: count,
                lastStrikeAt: lastStrikeAt
            )
    }

    private static func isCompatible(
        _ row: SyncCheckpoint,
        accountEmail: String
    ) -> Bool {
        row.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame &&
            row.startHistoryId == nil &&
            row.pageToken == nil
    }

    private static func decodePayload(from row: SyncCheckpoint) -> Payload? {
        guard let payloadJSON = row.pendingMessageIdsJSON,
              let payloadData = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.version == Payload.currentVersion,
              payload.consecutiveFailureCount >= 0 else {
            return nil
        }
        return payload
    }

    private static func apply(
        count: Int,
        lastStrikeAt: Date?,
        accountEmail: String,
        to checkpoint: SyncCheckpoint,
        now: Date
    ) throws {
        guard count >= 0 else {
            throw SyncFailureCounterCheckpointStoreError.invalidFailureCount(count)
        }
        let payload = Payload(
            version: Payload.currentVersion,
            consecutiveFailureCount: count,
            lastStrikeAt: lastStrikeAt
        )
        let payloadData = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        checkpoint.accountEmail = accountEmail
        checkpoint.startHistoryId = nil
        checkpoint.pageToken = nil
        checkpoint.pendingMessageIdsJSON = payloadJSON
        checkpoint.updatedAt = now
    }

    private static func sanitizedLegacyCount(_ count: Int?) -> Int {
        guard let count, count >= 0 else { return 0 }
        return count
    }

    private static func hasCommittedAccount(
        matching accountEmail: String,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = Account.fetchRequest()
        request.includesPendingChanges = false
        return try context.fetch(request).contains { account in
            account.email.caseInsensitiveCompare(accountEmail) == .orderedSame
        }
    }

    private static func deleteDuplicates(
        except selected: SyncCheckpoint,
        from rows: [SyncCheckpoint],
        in context: NSManagedObjectContext
    ) {
        for row in rows where row.objectID != selected.objectID {
            context.delete(row)
        }
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
