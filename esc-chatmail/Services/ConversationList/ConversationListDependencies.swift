struct ConversationListDependencies {
    let storage: StorageDependencies
    let messaging: MessagingDependencies
    let syncEngine: SyncEngine
    let foregroundSyncCoordinator: ForegroundSyncCoordinator
    let conversationManager: ConversationManager
    let makeConversationSearchService: @MainActor () -> ConversationSearchService
    let makeConversationSelectionService: @MainActor () -> ConversationSelectionService
    let makeConversationFilterService: @MainActor () -> ConversationFilterService
}
