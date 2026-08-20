import Foundation

struct ConversationListDependencies {
    let storage: StorageDependencies
    let messaging: MessagingDependencies
    /// Awaited by the launch preview repair before it sweeps, so the sweep
    /// never races a sync run mid-save. Production passes the `SyncEngine`;
    /// tests inject a controllable waiter.
    let syncWaiter: any ForegroundSyncPerforming
    let foregroundSyncCoordinator: ForegroundSyncCoordinator
    let conversationManager: ConversationManager
    /// Source of `.syncCompleted` for the launch repair's re-arm.
    var notificationCenter: NotificationCenter = .default
    let makeConversationSearchService: @MainActor () -> ConversationSearchService
    let makeConversationSelectionService: @MainActor () -> ConversationSelectionService
    let makeConversationFilterService: @MainActor () -> ConversationFilterService
}
