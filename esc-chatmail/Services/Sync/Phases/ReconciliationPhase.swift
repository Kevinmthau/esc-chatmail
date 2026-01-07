import Foundation
import CoreData

/// Input for reconciliation phase
struct ReconciliationInput {
    /// Skip label reconciliation when history reported no changes
    let skipLabelReconciliation: Bool
}

/// Phase 4: Reconciliation to catch missed messages
struct ReconciliationPhase: SyncPhase {
    typealias Input = ReconciliationInput
    typealias Output = Void

    let name = "Reconciliation"
    let progressRange: ClosedRange<Double> = 0.8...0.85

    private let reconciliation: SyncReconciliation
    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    private let log = LogCategory.sync.logger

    init(
        reconciliation: SyncReconciliation,
        messageFetcher: MessageFetcher,
        messagePersister: MessagePersister
    ) {
        self.reconciliation = reconciliation
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
    }

    func execute(
        input: ReconciliationInput,
        context: SyncPhaseContext
    ) async throws {
        try Task.checkCancellation()

        context.reportProgress(0, status: "Checking for missed messages...", phase: self)

        let installTimestamp = UserDefaults.standard.double(forKey: "installTimestamp")

        // Check for missed messages
        let missedIds = await reconciliation.checkForMissedMessages(
            in: context.coreDataContext,
            installTimestamp: installTimestamp
        )

        if !missedIds.isEmpty {
            log.info("Reconciliation found \(missedIds.count) missed messages")

            context.reportProgress(0.5, status: "Recovering \(missedIds.count) missed messages...", phase: self)

            let failedMissedIds = await BatchProcessor.retryFailedMessages(
                failedIds: missedIds,
                messageFetcher: messageFetcher
            ) { [messagePersister] message in
                await messagePersister.saveMessage(
                    message,
                    labelIds: context.labelIds,
                    myAliases: context.myAliases,
                    in: context.coreDataContext
                )
            }

            if !failedMissedIds.isEmpty {
                log.warning("Failed to fetch \(failedMissedIds.count) missed messages")
            }
        }

        // Skip label reconciliation when history reported no changes
        if input.skipLabelReconciliation {
            log.debug("Skipping label reconciliation (no history changes)")
        } else {
            context.reportProgress(0.8, status: "Reconciling labels...", phase: self)
            await reconciliation.reconcileLabelStates(in: context.coreDataContext, labelIds: context.labelIds)
        }

        context.reportProgress(1.0, status: "Reconciliation complete", phase: self)
    }
}
