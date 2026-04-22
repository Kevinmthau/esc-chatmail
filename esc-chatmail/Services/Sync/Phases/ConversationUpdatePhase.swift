import Foundation
import CoreData

/// Phase 5: Update conversation rollups for modified conversations
struct ConversationUpdatePhase: SyncPhase {
    typealias Input = Set<NSManagedObjectID>
    typealias Output = Void

    let name = "Conversation Update"
    let progressRange: ClosedRange<Double> = 0.95...1.0

    private let updateRollups: @MainActor @Sendable (Set<NSManagedObjectID>, NSManagedObjectContext) async -> Void
    private let log = LogCategory.sync.logger

    init(conversationManager: ConversationManager) {
        self.updateRollups = { conversationIDs, context in
            await conversationManager.updateRollupsForModifiedConversations(
                conversationIDs: conversationIDs,
                in: context
            )
        }
    }

    init(
        updateRollups: @escaping @MainActor @Sendable (Set<NSManagedObjectID>, NSManagedObjectContext) async -> Void
    ) {
        self.updateRollups = updateRollups
    }

    func execute(
        input modifiedIDs: Set<NSManagedObjectID>,
        context: SyncPhaseContext
    ) async throws {
        context.reportProgress(0, status: "Updating conversations...", phase: self)

        log.debug("Updating rollups for \(modifiedIDs.count) modified conversations")

        if !modifiedIDs.isEmpty {
            await updateRollups(modifiedIDs, context.coreDataContext)
        }

        context.reportProgress(1.0, status: "Conversations updated", phase: self)
    }
}
