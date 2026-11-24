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
