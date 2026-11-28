import CoreData
import Foundation

/// Turns a "Delivery unknown" send that Gmail provably never received into
/// "Not sent", in the caller's context, for `DeliveryUnknownProbe`.
///
/// The effects are `GmailSendService.retainDefinitelyUnsentOptimisticMessage`'s,
/// written without the view context because the probe runs inside a sync run
/// and its change must commit at that run's save point, or not at all: the
/// `notSent` marker, the forward envelope's consumed recovery source dropped,
/// and the message's own local attachments marked failed. It adds a
/// `failureReason`, which the Not-sent alert shows. Keep the two in step.
enum DeliveryUnknownResolution {
    static let notSentReason =
        "Gmail has no copy of this message, so it was not sent. Choose Edit and resend to send it."

    /// Stages the change on the record with this optimistic ID, compare-and-set
    /// from "Delivery unknown" only: a record in any other state (consumed by
    /// an echo, already Not sent, a committed send), or one whose message row
    /// is gone, is left alone and `false` is returned. Call inside the context's `perform`. Nothing is saved.
    static func stageNotSent(
        optimisticMessageID: String,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", optimisticMessageID)
        request.includesPendingChanges = true
        let records = try context.fetch(request)
        guard records.count == 1,
              let record = records.first,
              !record.isDeleted,
              record.remoteCommittedMessageId == OutboundSendRemoteState.ambiguousMessageID,
              record.remoteCommittedThreadId == nil else {
            return false
        }
        let messageRequest = Message.fetchRequest()
        messageRequest.predicate = MessagePredicates.id(optimisticMessageID)
        messageRequest.includesPendingChanges = true
        let messages = try context.fetch(messageRequest).filter { !$0.isDeleted }
        // `retainDefinitelyUnsentOptimisticMessage` never marks a record whose
        // message row is gone: it restores the conversation and drops the
        // record instead, which needs the view context. Leave such a record
        // as it is rather than write a marker that path never writes.
        guard !messages.isEmpty else { return false }

        record.remoteCommittedMessageId = OutboundSendRemoteState.notSentMessageID
        record.failureReason = notSentReason
        if let envelope = try? StoredForwardEnvelope.decode(from: record.replyEnvelopeData),
           envelope.recoverySourceWasConsumed == true {
            record.replyEnvelopeData = try envelope.withoutRecoverySource().encoded()
        }

        for message in messages {
            for attachment in message.attachmentsArray where attachment.isLocalAttachment {
                attachment.state = .failed
            }
        }
        return true
    }

    /// How far around the send the store is read for a message the search may
    /// have missed: device and Gmail clocks, and Gmail's own processing.
    static let storeWitnessSlack: TimeInterval = 15 * 60

    /// The store's own witnesses that Gmail never committed this send, asked
    /// before an empty search is taken as "Not sent". Either one says no:
    /// - a sync ledger row (`AbandonedSyncMessage`, in any state) recorded
    ///   since the send: a message sync could not store, which may be this
    ///   send's echo, and the history witness cannot see it. A row the drain
    ///   gave up on is kept, `exhausted`, and goes on holding the verdict until
    ///   its message is stored, a Retry from the banner resolves it (stored or
    ///   gone) or it is cleared (architecture review 2026-11,
    ///   sync-persist-path#6): a false "Not sent" invites a duplicate resend,
    ///   and "Delivery unknown" a little longer costs nothing. Never narrow
    ///   this to rows the drain still retries. An unprocessable message leaves
    ///   no row, so this covers only failures on record;
    /// - a stored message, anywhere, carrying this send's own Message-ID: its
    ///   echo, kept without consuming the record;
    /// - a message from the user in the send's own conversation, dated within
    ///   the send's request lifetime (two `sendResourceTimeout`s) of its
    ///   admission, that does not carry one of the app's deterministic
    ///   Message-IDs: what this send's echo would look like if Gmail had not
    ///   kept our Message-ID, in which case the search could not find it
    ///   either. An echo of another of the app's sends carries its own ID and
    ///   is no witness.
    /// Call inside the context's `perform`.
    static func storeAgreesItWasNotSent(
        optimisticMessageID: String,
        admittedAt: Date,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let since = admittedAt.addingTimeInterval(-storeWitnessSlack)
        let ledgerRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "AbandonedSyncMessage")
        ledgerRequest.predicate = NSPredicate(format: "abandonedAt >= %@", since as NSDate)
        ledgerRequest.includesPendingChanges = true
        guard try context.count(for: ledgerRequest) == 0 else { return false }

        // A stored row carrying this send's own Message-ID is its echo, which
        // the persister keeps without consuming the record in some routes
        // (an unresolved anchor). Store-wide: the echo may be in another
        // conversation. Unindexed, but asked at most a few times a run.
        let echoRequest = Message.fetchRequest()
        echoRequest.predicate = NSPredicate(
            format: "messageId == %@ AND id != %@",
            MimeBuilder.messageId(forOptimisticMessageID: optimisticMessageID),
            optimisticMessageID
        )
        echoRequest.includesPendingChanges = true
        guard try context.fetch(echoRequest).allSatisfy(\.isDeleted) else { return false }

        let ownRequest = Message.fetchRequest()
        ownRequest.predicate = MessagePredicates.id(optimisticMessageID)
        ownRequest.includesPendingChanges = true
        guard let conversation = try context.fetch(ownRequest).first(where: { !$0.isDeleted })?.conversation else {
            return false
        }
        let until = admittedAt.addingTimeInterval(2 * NetworkConfig.sendResourceTimeout + storeWitnessSlack)
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(
            format: "conversation == %@ AND isFromMe == YES AND internalDate >= %@ AND internalDate <= %@ AND id != %@",
            conversation.objectID, since as NSDate, until as NSDate, optimisticMessageID
        )
        request.includesPendingChanges = true
        for message in try context.fetch(request) where !message.isDeleted {
            guard message.messageIdValue.flatMap(MimeBuilder.optimisticMessageID(from:)) != nil else {
                return false
            }
        }
        return true
    }

    /// Records that the probe asked about this send without resolving it here
    /// (found, whose echo may not consume it, or no verdict), so it is not
    /// asked again for `DeliveryUnknownProbePolicy.reprobeInterval`. Still
    /// "Delivery unknown" only.
    static func stageLookedUp(
        optimisticMessageID: String,
        probedAt: Date,
        in context: NSManagedObjectContext
    ) throws {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", optimisticMessageID)
        request.includesPendingChanges = true
        for record in try context.fetch(request)
            where !record.isDeleted
            && record.remoteCommittedMessageId == OutboundSendRemoteState.ambiguousMessageID {
            record.deliveryProbedAt = probedAt
        }
    }
}
