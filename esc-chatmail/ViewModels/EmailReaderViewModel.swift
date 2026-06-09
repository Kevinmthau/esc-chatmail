import Foundation
import CoreData

@MainActor
final class EmailReaderViewModel: ObservableObject {
    let route: EmailReaderRoute

    @Published private(set) var session: FullEmailOpenSession?
    @Published private(set) var errorMessage: String?

    private let viewContext: NSManagedObjectContext
    private let fullEmailReaderCoordinator: FullEmailReaderCoordinator

    init(
        route: EmailReaderRoute,
        chatDependencies: ChatDependencies
    ) {
        self.route = route
        self.viewContext = chatDependencies.storage.viewContext
        self.fullEmailReaderCoordinator = FullEmailReaderCoordinator(
            fullEmailOpener: chatDependencies.fullEmailOpener
        )
        resolveRoute()
    }

    init(
        route: EmailReaderRoute,
        viewContext: NSManagedObjectContext,
        fullEmailReaderCoordinator: FullEmailReaderCoordinator
    ) {
        self.route = route
        self.viewContext = viewContext
        self.fullEmailReaderCoordinator = fullEmailReaderCoordinator
        resolveRoute()
    }

    func retryResolveRoute() {
        resolveRoute()
    }

    private func resolveRoute() {
        guard let message = resolveMessage(with: route.messageObjectID) else {
            session = nil
            errorMessage = "Original email unavailable"
            Log.error("EmailReaderViewModel could not resolve routed message", category: .ui)
            return
        }

        errorMessage = nil
        session = fullEmailReaderCoordinator.openSession(for: message)
    }

    private func resolveMessage(with objectID: NSManagedObjectID) -> Message? {
        if let registered = viewContext.registeredObject(for: objectID) as? Message,
           !registered.isDeleted {
            return registered
        }

        guard let resolved = try? viewContext.existingObject(with: objectID) as? Message,
              !resolved.isDeleted else {
            return nil
        }

        return resolved
    }
}
