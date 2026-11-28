import Foundation
import CoreData

/// What a refetch changes about a stored message's labels: the stored labels
/// Gmail no longer reports, and the labels Gmail reports that the row lacks.
/// A refetch that changed nothing writes nothing.
///
/// Why a diff (architecture review 2026-11, `sync-persist-path#1`):
/// `Label.messages` is the inverse of `Message.labels`, and each write to the
/// relationship makes Core Data read that label's whole membership into the
/// writing context. INBOX holds most of the mailbox. The update path cleared
/// the row's labels and added Gmail's back (`labels = nil`), so every refetch
/// of an INBOX row, which is every row a held cursor's re-scan or a history
/// recovery's re-list meets, read every INBOX member into the run's fresh
/// context: 99,877 objects for one unchanged row of the S2 store
/// (`ScaleHubFaultTests`, iOS 27.0 simulator, 2026-11-28). A label that did
/// change still pays that read until model 9 takes the system labels off the
/// relationship.
///
/// Three rules hold it, and each fails silently when broken.
/// - A stored label stays while Gmail still reports its ID, whichever row of
///   that ID it is: duplicate Label rows are legal until the merge pass
///   repairs them (`LabelPersister.fetchLabelsByIds`), and trading one
///   duplicate for another would write on every refetch.
/// - An incoming ID with no Label row is not a difference: nothing can be
///   added for it, and counting it would make every refetch of that message
///   write.
/// - Only the IDs the row lacks are read, so an unchanged refetch reads no
///   Label, and a read that fails throws. As an empty answer it was "Gmail's
///   labels have no rows", which stripped every label, after which the rollup
///   saved a zero unread count behind an advancing cursor.
struct ExistingMessageLabelDiff {
    /// Stored labels whose ID Gmail no longer reports, in ID order.
    let removals: [Label]
    /// Rows for the reported IDs the message lacks, in Gmail's order.
    let additions: [Label]

    /// Call on the labels' context queue.
    /// - Parameters:
    ///   - storedLabels: the row's labels as stored.
    ///   - incomingLabelIds: the labels Gmail reports for the message.
    ///   - availableLabelIds: the run's prefetched label IDs
    ///     (`MessagePersister.prefetchLabelIds`). They only narrow the read, as
    ///     on the create path: an empty set is a prefetch that failed, and
    ///     narrows nothing.
    ///   - fetchLabels: reads the rows for a set of label IDs; it is called
    ///     once, and never with IDs the row already has.
    static func plan(
        storedLabels: Set<Label>,
        incomingLabelIds: [String],
        availableLabelIds: Set<String>?,
        fetchLabels: (Set<String>) throws -> [String: Label]
    ) throws -> ExistingMessageLabelDiff {
        let incoming = Set(incomingLabelIds)
        let removals = storedLabels
            .filter { !incoming.contains($0.id) }
            .sorted { $0.id < $1.id }

        var missingIDs = incoming.subtracting(storedLabels.map(\.id))
        if let availableLabelIds, !availableLabelIds.isEmpty {
            missingIDs.formIntersection(availableLabelIds)
        }
        let fetched = missingIDs.isEmpty ? [:] : try fetchLabels(missingIDs)
        var added = Set<String>()
        let additions = incomingLabelIds.compactMap { id -> Label? in
            guard missingIDs.contains(id), added.insert(id).inserted else { return nil }
            return fetched[id]
        }
        return ExistingMessageLabelDiff(removals: removals, additions: additions)
    }
}
