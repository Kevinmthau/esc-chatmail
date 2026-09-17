import Foundation
import CoreData
@testable import esc_chatmail

/// `MessageActionsCoreDataStacking` over a `TestCoreDataStack`, with a
/// main-queue `viewContext` from `TestCoreDataStack.makeMainQueueViewContext()`.
///
/// `MessageActions` is `@MainActor` and fetches, mutates, and saves
/// `coreDataStack.viewContext` directly. A bare `TestCoreDataStack` would hand
/// it the stack's private-queue context, so every such access would be
/// off-queue (see that helper for what the private-queue shape races). Suites
/// using this route their fixtures, saves, and assertions through this
/// `viewContext` too. Background contexts and `saveIfNeeded` forward to the
/// wrapped stack.
///
/// Create it on the main actor and use `viewContext` only from there.
/// `TestCoreDataStack` deliberately no longer conforms to
/// `MessageActionsCoreDataStacking` itself: the private-queue context that
/// conformance vended is the bug this type exists to avoid.
final class MainQueueMessageActionsCoreDataStack: MessageActionsCoreDataStacking {
    let stack: TestCoreDataStack
    let viewContext: NSManagedObjectContext

    @MainActor
    init(wrapping stack: TestCoreDataStack) {
        self.stack = stack
        self.viewContext = stack.makeMainQueueViewContext()
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        stack.newBackgroundContext()
    }

    @discardableResult
    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool {
        stack.saveIfNeeded(context: context, caller: caller)
    }
}
