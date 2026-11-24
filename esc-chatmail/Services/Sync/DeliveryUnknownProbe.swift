import CoreData
import Foundation

/// Looks up "Delivery unknown" sends in Gmail by their deterministic Message-ID
/// and resolves the ones it can (`DeliveryUnknownProbePolicy`), inside an
/// incremental sync run (`ReconciliationPhase`). It never sends.
///
/// Its writes are staged in the run's context and commit at the run's save
/// point or die with it, like every other write of the run. Found messages are
/// returned for the run to persist through `MessagePersister.saveMessages`,
/// whose echo matching consumes the record; a record Gmail has no copy of is
/// staged as "Not sent". An API failure is no verdict. Every lookup that got
/// an answer or an ordinary failure stamps `deliveryProbedAt`, which spaces
/// the next one by `DeliveryUnknownProbePolicy.reprobeInterval`. Cancellation and
/// account-scoped failures (`APIError.isAccountScopedSyncAbort`) abort the
/// run, as they do for every request of it.
struct DeliveryUnknownProbe {
    struct Outcome: Equatable, Sendable {
        /// Gmail message IDs the search returned, for the run to persist.
        var foundMessageIDs: [String] = []
        /// Optimistic IDs staged as "Not sent".
        var resolvedAsNotSent: [String] = []
        /// Optimistic IDs looked up with no verdict.
        var unresolved: [String] = []
    }

    let messageFetcher: MessageFetcher
    private let log = LogCategory.sync.logger

    init(messageFetcher: MessageFetcher) {
        self.messageFetcher = messageFetcher
    }

    func run(
        runStartedAt: Date,
        in context: NSManagedObjectContext
    ) async throws -> Outcome {
        let candidates = try await context.perform {
            let request = OutboundSendMutationRecord.fetchRequest()
            request.predicate = NSPredicate(
                format: "remoteCommittedMessageId == %@",
                OutboundSendRemoteState.ambiguousMessageID
            )
            request.includesPendingChanges = true
            return try context.fetch(request).map {
                DeliveryUnknownProbePolicy.Candidate(
                    optimisticMessageID: $0.id,
                    remoteCommittedMessageId: $0.remoteCommittedMessageId,
                    remoteCommittedThreadId: $0.remoteCommittedThreadId,
                    admittedAt: $0.admittedAt,
                    deliveryProbedAt: $0.deliveryProbedAt
                )
            }
        }
        let toProbe = DeliveryUnknownProbePolicy.candidatesToProbe(
            candidates,
            runStartedAt: runStartedAt
        )
        var outcome = Outcome()
        for candidate in toProbe {
            try Task.checkCancellation()
            let answer: DeliveryUnknownProbePolicy.Answer
            do {
                let (messageIDs, nextPageToken) = try await messageFetcher.searchAllMessages(
                    query: DeliveryUnknownProbePolicy.query(
                        forOptimisticMessageID: candidate.optimisticMessageID
                    ),
                    maxResults: 10
                )
                answer = .listed(messageIDs: messageIDs, nextPageToken: nextPageToken)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let apiError = error as? APIError, apiError.isAccountScopedSyncAbort {
                    throw apiError
                }
                log.error(
                    "Delivery-unknown lookup failed for \(Log.hashIdentifier(candidate.optimisticMessageID)); no verdict",
                    error: error
                )
                answer = .failed
            }
            // The answer is used only by a run that is still live: a run
            // cancelled meanwhile (an account transition's quiescence
            // included) stages nothing.
            try Task.checkCancellation()

            switch DeliveryUnknownProbePolicy.verdict(for: answer) {
            case .found(let messageIDs):
                try await context.perform {
                    try DeliveryUnknownResolution.stageLookedUp(
                        optimisticMessageID: candidate.optimisticMessageID,
                        probedAt: runStartedAt,
                        in: context
                    )
                }
                outcome.foundMessageIDs.append(contentsOf: messageIDs)
            case .notFound:
                let staged = try await context.perform {
                    if let admittedAt = candidate.admittedAt,
                       try DeliveryUnknownResolution.storeAgreesItWasNotSent(
                           optimisticMessageID: candidate.optimisticMessageID,
                           admittedAt: admittedAt,
                           in: context
                       ),
                       try DeliveryUnknownResolution.stageNotSent(
                           optimisticMessageID: candidate.optimisticMessageID,
                           in: context
                       ) {
                        return true
                    }
                    // The store holds something the search could have missed,
                    // or the record cannot be resolved here (its message row
                    // is gone): no verdict, spaced like any other.
                    try DeliveryUnknownResolution.stageLookedUp(
                        optimisticMessageID: candidate.optimisticMessageID,
                        probedAt: runStartedAt,
                        in: context
                    )
                    return false
                }
                if staged {
                    outcome.resolvedAsNotSent.append(candidate.optimisticMessageID)
                } else {
                    outcome.unresolved.append(candidate.optimisticMessageID)
                }
            case .none:
                // Not a verdict, only a record that it was asked: the next
                // lookup waits `reprobeInterval`, so a record whose lookup
                // keeps failing cannot hold the run's few lookups for good.
                try await context.perform {
                    try DeliveryUnknownResolution.stageLookedUp(
                        optimisticMessageID: candidate.optimisticMessageID,
                        probedAt: runStartedAt,
                        in: context
                    )
                }
                outcome.unresolved.append(candidate.optimisticMessageID)
            }
        }
        if !toProbe.isEmpty {
            log.info(
                "Delivery-unknown lookups: probed=\(toProbe.count) found=\(outcome.foundMessageIDs.count) notSent=\(outcome.resolvedAsNotSent.count) unresolved=\(outcome.unresolved.count)"
            )
        }
        return outcome
    }
}
