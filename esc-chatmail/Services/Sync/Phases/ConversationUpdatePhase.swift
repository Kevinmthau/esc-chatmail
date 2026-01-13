import Foundation
import CoreData

/// Phase 5: Update conversation rollups for modified conversations
struct ConversationUpdatePhase: SyncPhase {
    typealias Input = Void
    typealias Output = Void

    let name = "Conversation Update"
    let progressRange: ClosedRange<Double> = 0.85...0.95

    private let conversationManager: ConversationManager
    private let dataCleanupService: DataCleanupService
    private let messagePersister: MessagePersister
    private let historyProcessor: HistoryProcessor
    private let log = LogCategory.sync.logger

    init(
        conversationManager: ConversationManager,
        dataCleanupService: DataCleanupService,
        messagePersister: MessagePersister,
        historyProcessor: HistoryProcessor
    ) {
        self.conversationManager = conversationManager
        self.dataCleanupService = dataCleanupService
        self.messagePersister = messagePersister
        self.historyProcessor = historyProcessor
    }

    func execute(
        input: Void,
        context: SyncPhaseContext
    ) async throws {
        context.reportProgress(0, status: "Updating conversations...", phase: self)

        // Use the shared ModificationTracker which consolidates tracking from both
        // MessagePersister and HistoryProcessor
        let modifiedIDs = await ModificationTracker.shared.getAndClearModifiedConversations()

        log.debug("Updating rollups for \(modifiedIDs.count) modified conversations")

        if !modifiedIDs.isEmpty {
            await conversationManager.updateRollupsForModifiedConversations(
                conversationIDs: modifiedIDs,
                in: context.coreDataContext
            )
        }

        context.reportProgress(0.7, status: "Running cleanup...", phase: self)
        await dataCleanupService.runIncrementalCleanup(in: context.coreDataContext)

        context.reportProgress(1.0, status: "Conversations updated", phase: self)
    }
}
