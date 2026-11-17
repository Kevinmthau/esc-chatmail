import Foundation
import CoreData
@testable import esc_chatmail

/// Wraps a main-queue test stack and hands `MessageActions` background
/// contexts that count their fetches, so a test can tell when a fetch made
/// on one of them has run.
final class FetchCountingMessageActionsStack: MessageActionsCoreDataStacking, @unchecked Sendable {
    private let wrapped: MainQueueMessageActionsCoreDataStack
    private let contexts: FetchCountingContextFactory

    init(wrapping wrapped: MainQueueMessageActionsCoreDataStack, coordinator: NSPersistentStoreCoordinator) {
        self.wrapped = wrapped
        self.contexts = FetchCountingContextFactory(coordinator: coordinator)
    }

    var viewContext: NSManagedObjectContext { wrapped.viewContext }

    func fetchCount(ofEntity entityName: String) -> Int {
        contexts.fetchCount(ofEntity: entityName)
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        contexts.makeContext()
    }

    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool {
        wrapped.saveIfNeeded(context: context, caller: caller)
    }
}
