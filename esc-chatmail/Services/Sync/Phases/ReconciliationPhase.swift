import Foundation
import CoreData

/// Input for reconciliation phase
struct ReconciliationInput {
    /// Skip label reconciliation when history reported no changes
    let skipLabelReconciliation: Bool
    /// List missed messages but leave their fetches, with any deferred
    /// earlier, to a sync with a larger budget (an app refresh).
    var defersMissedMessageFetches = false
}

struct ReconciliationPhaseResult: Sendable, Equatable {
    let diagnostics: SyncReconciliationDiagnostics
    let labelOutcome: LabelReconciliationOutcome
    /// Deferred missed-message IDs this run tried to fetch. The orchestrator
    /// forgets them only once the run has saved.
    var attemptedDeferredMissedIds: [String] = []
}

/// Phase 4: Reconciliation to catch missed messages
struct ReconciliationPhase: SyncPhase {
    typealias Input = ReconciliationInput
    typealias Output = ReconciliationPhaseResult

    let name = "Reconciliation"
    let progressRange: ClosedRange<Double> = 0.8...0.85

    private let reconciliation: SyncReconciliation
    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    /// Where `installTimestamp` is read from: the orchestrator's store.
    private let defaults: UserDefaults
    private let log = LogCategory.sync.logger

    init(
        reconciliation: SyncReconciliation,
        messageFetcher: MessageFetcher,
        messagePersister: MessagePersister,
        defaults: UserDefaults = .standard
    ) {
        self.reconciliation = reconciliation
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
        self.defaults = defaults
    }

    func execute(
        input: ReconciliationInput,
        context: SyncPhaseContext
    ) async throws -> ReconciliationPhaseResult {
        try Task.checkCancellation()
        var diagnostics = SyncReconciliationDiagnostics()
        let labelOutcome: LabelReconciliationOutcome

        context.reportProgress(0, status: "Checking for missed messages...", phase: self)

        let installTimestamp = defaults.double(forKey: SyncConfig.mailboxStartTimestampKey)

        // Check for missed messages
        let missedResult = await reconciliation.checkForMissedMessagesWithDiagnostics(
            in: context.coreDataContext,
            installTimestamp: installTimestamp
        )
        diagnostics.merge(missedResult.diagnostics)

        if input.defersMissedMessageFetches {
            // The list call above is the per-sync safety net and stays; the
            // fetches it calls for can be hundreds of full messages, which
            // an app refresh's half minute cannot hold.
            if !missedResult.missingIds.isEmpty {
                log.info("Deferring \(missedResult.missingIds.count) missed-message fetches to a sync with a larger budget")
                reconciliation.deferMissedMessageFetches(missedResult.missingIds)
            }
        }

        var attemptedDeferredMissedIds: [String] = []
        var missedIds: [String] = []
        if !input.defersMissedMessageFetches {
            let deferred = await reconciliation.deferredMissedMessageIds(in: context.coreDataContext)
            attemptedDeferredMissedIds = deferred.deferred
            var seen = Set<String>()
            missedIds = (missedResult.missingIds + deferred.stillMissing).filter {
                seen.insert($0).inserted
            }
        }

        if !missedIds.isEmpty {
            log.info("Reconciliation found \(missedIds.count) missed messages")

            context.reportProgress(0.5, status: "Recovering \(missedIds.count) missed messages...", phase: self)

            let recoveryOutcome = try await BatchProcessor.retryFailedMessages(
                failedIds: missedIds,
                messageFetcher: messageFetcher
            ) { [messagePersister] messages in
                try await messagePersister.saveMessages(
                    messages,
                    labelIds: context.labelIds,
                    myAliases: context.myAliases,
                    sendAsAliases: context.sendAsAliases,
                    modificationTransaction: context.modificationTransaction,
                    in: context.coreDataContext
                )
            }

            if recoveryOutcome.hasBlockingFailures {
                // Missed-message recovery is a safety net outside history
                // semantics; failures here are logged, not cursor-gating.
                log.warning("Failed to recover \(recoveryOutcome.blockingFailureIds.count) missed messages")
            }
        }

        // Skip label reconciliation when history reported no changes
        if input.skipLabelReconciliation {
            log.debug("Skipping label reconciliation (no history changes)")
            labelOutcome = .notRequested
        } else {
            context.reportProgress(0.8, status: "Reconciling labels...", phase: self)
            let labelResult = await reconciliation.reconcileLabelStatesWithDiagnostics(
                in: context.coreDataContext,
                labelIds: context.labelIds,
                modificationTransaction: context.modificationTransaction
            )
            diagnostics.merge(labelResult.diagnostics)
            labelOutcome = labelResult.outcome
        }

        try Task.checkCancellation()
        logDiagnostics(diagnostics)
        context.reportProgress(1.0, status: "Reconciliation complete", phase: self)
        return ReconciliationPhaseResult(
            diagnostics: diagnostics,
            labelOutcome: labelOutcome,
            attemptedDeferredMissedIds: attemptedDeferredMissedIds
        )
    }

    private func logDiagnostics(_ diagnostics: SyncReconciliationDiagnostics) {
        let message = "Reconciliation diagnostics: \(diagnostics.summary)"
        if diagnostics.hasWarnings {
            log.warning("\(message)")
        } else if diagnostics.hasFindings {
            log.info("\(message)")
        } else {
            log.debug("\(message)")
        }
    }
}
