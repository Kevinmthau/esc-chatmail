import Foundation
import CoreData
@testable import esc_chatmail

extension ConversationListDependencies {
    /// Builds a conversation-list dependency bundle whose storage, migration
    /// flags, and contact loader are test-owned, so a view model constructed
    /// with it never reaches `CoreDataStack.shared` or
    /// `UserDefaults.standard`. In particular, the launch passes the view
    /// model schedules from `onAppear(in:)` (`refreshConversationNames`,
    /// `repairMissingConversationPreviews`) run against the given
    /// `TestCoreDataStack`'s store instead of the shared on-disk store.
    ///
    /// Not yet isolated: `foregroundSyncCoordinator`, `messaging`,
    /// `personCache`, and `profilePhotoResolver` still come from
    /// `Dependencies.shared` because no test seam exists for them yet.
    ///
    /// - Parameters:
    ///   - stack: The suite's `TestCoreDataStack`; supplies the view context,
    ///     background contexts, and saves.
    ///   - migrationFlags: Test-owned migration flag storage. Defaults to a
    ///     fresh `InMemoryMigrationFlagStore`, so one-shot launch guards start
    ///     unset for every test.
    ///   - contactEmailLoader: Loader for the default filter service's contact
    ///     cache. Defaults to an inert empty loader so tests never touch the
    ///     real Contacts store. Ignored when `filterService` is supplied.
    ///   - conversationManager: Override for the launch passes' manager.
    ///     Defaults to a fresh manager with a fixed test user email.
    ///   - syncWaiter: Sync-idle wait awaited by the launch preview repair.
    ///     Defaults to a `MockForegroundSyncEngine` that returns immediately,
    ///     so tests never await the shared `SyncEngine`.
    ///   - notificationCenter: Source of `.syncCompleted` for the launch
    ///     repair's re-arm. Defaults to `.default`, matching the existing
    ///     suites that post the notification on the default center.
    ///   - searchService: Optional service override returned by the bundle's
    ///     search factory (e.g. to shorten the debounce interval).
    ///   - selectionService: Optional service override returned by the
    ///     bundle's selection factory. The default service resolves its batch
    ///     actions on `stack`'s view context; its `MessageActions` still
    ///     comes from `Dependencies.shared` (no test seam yet).
    ///   - filterService: Optional service override returned by the bundle's
    ///     filter factory; takes precedence over `contactEmailLoader`.
    @MainActor
    static func forTesting(
        stack: TestCoreDataStack,
        migrationFlags: MigrationFlagStore = InMemoryMigrationFlagStore(),
        contactEmailLoader: ConversationFilterService.ContactEmailLoader? = nil,
        conversationManager: ConversationManager? = nil,
        syncWaiter: (any ForegroundSyncPerforming)? = nil,
        notificationCenter: NotificationCenter = .default,
        searchService: ConversationSearchService? = nil,
        selectionService: ConversationSelectionService? = nil,
        filterService: ConversationFilterService? = nil
    ) -> ConversationListDependencies {
        let resolvedSearchService = searchService ?? ConversationSearchService()
        let resolvedSelectionService = selectionService ?? ConversationSelectionService(
            messageActions: Dependencies.shared.makeMessageActions(),
            viewContext: stack.viewContext
        )
        let resolvedFilterService = filterService ?? ConversationFilterService(
            contactEmailLoader: contactEmailLoader ?? { _ in [] }
        )
        let resolvedConversationManager = conversationManager
            ?? ConversationManager(currentUserEmail: { "me@example.com" })
        let resolvedSyncWaiter = syncWaiter ?? MockForegroundSyncEngine()

        return ConversationListDependencies(
            storage: StorageDependencies(
                viewContext: stack.viewContext,
                makeBackgroundContext: { stack.newBackgroundContext() },
                saveIfNeeded: { stack.saveIfNeeded(context: $0) },
                migrationFlags: migrationFlags,
                personCache: Dependencies.shared.personCache,
                profilePhotoResolver: Dependencies.shared.profilePhotoResolver
            ),
            messaging: Dependencies.shared.makeMessagingDependencies(),
            syncWaiter: resolvedSyncWaiter,
            foregroundSyncCoordinator: Dependencies.shared.foregroundSyncCoordinator,
            conversationManager: resolvedConversationManager,
            notificationCenter: notificationCenter,
            makeConversationSearchService: { resolvedSearchService },
            makeConversationSelectionService: { resolvedSelectionService },
            makeConversationFilterService: { resolvedFilterService }
        )
    }
}
