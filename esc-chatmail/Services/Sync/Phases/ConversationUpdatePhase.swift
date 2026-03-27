import Foundation
import CoreData

/// Phase 5: Update conversation rollups for modified conversations
struct ConversationUpdatePhase: SyncPhase {
    typealias Input = Void
    typealias Output = Void

    let name = "Conversation Update"
    let progressRange: ClosedRange<Double> = 0.85...0.95

    private let conversationManager: ConversationManager
    private let log = LogCategory.sync.logger

    init(conversationManager: ConversationManager) {
        self.conversationManager = conversationManager
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

        context.reportProgress(1.0, status: "Conversations updated", phase: self)
    }
}
