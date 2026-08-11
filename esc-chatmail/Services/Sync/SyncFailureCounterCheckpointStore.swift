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
struct SyncFailureCounterCheckpointStore {
    private struct Payload: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let consecutiveFailureCount: Int
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

            let compatible = rows.lazy.compactMap { row -> (SyncCheckpoint, Int)? in
                guard Self.isCompatible(row, accountEmail: accountEmail),
                      let count = Self.decodeCount(from: row) else {
                    return nil
                }
                return (row, count)
            }.first
            if let (selected, count) = compatible {
                Self.deleteDuplicates(except: selected, from: rows, in: context)
                return SyncFailureCounterCheckpoint(
                    accountEmail: selected.accountEmail,
                    consecutiveFailureCount: count
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
                    accountEmail: accountEmail,
                    to: reusable,
                    now: Date()
                )
                Self.deleteDuplicates(except: reusable, from: rows, in: context)
                return SyncFailureCounterCheckpoint(
                    accountEmail: accountEmail,
                    consecutiveFailureCount: 0
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
                accountEmail: accountEmail,
                to: checkpoint,
                now: now
            )
            return SyncFailureCounterCheckpoint(
                accountEmail: accountEmail,
                consecutiveFailureCount: initialCount
            )
        }
    }

    /// Stages an exact counter value in the supplied context. Existing identity
    /// and creation time are preserved; unexpected duplicates are removed.
    func stage(
        consecutiveFailureCount: Int,
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
                accountEmail: accountEmail,
                to: checkpoint,
                now: now
            )
            Self.deleteDuplicates(except: checkpoint, from: rows, in: context)
        }
    }

    private static func isCompatible(
        _ row: SyncCheckpoint,
        accountEmail: String
    ) -> Bool {
        row.accountEmail.caseInsensitiveCompare(accountEmail) == .orderedSame &&
            row.startHistoryId == nil &&
            row.pageToken == nil
    }

    private static func decodeCount(from row: SyncCheckpoint) -> Int? {
        guard let payloadJSON = row.pendingMessageIdsJSON,
              let payloadData = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.version == Payload.currentVersion,
              payload.consecutiveFailureCount >= 0 else {
            return nil
        }
        return payload.consecutiveFailureCount
    }

    private static func apply(
        count: Int,
        accountEmail: String,
        to checkpoint: SyncCheckpoint,
        now: Date
    ) throws {
        guard count >= 0 else {
            throw SyncFailureCounterCheckpointStoreError.invalidFailureCount(count)
        }
        let payload = Payload(
            version: Payload.currentVersion,
            consecutiveFailureCount: count
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
