import Foundation
import CoreData
import Combine

/// Coordinates cache invalidation across multiple caches when Core Data changes.
///
/// Listens for NSManagedObjectContextDidSave notifications and invalidates
/// relevant caches to prevent stale data.
///
/// ## Usage
/// Initialize once at app startup:
/// ```swift
/// CacheCoordinator.shared.start()
/// ```
///
/// The coordinator automatically invalidates:
/// - PersonCache when Person entities are updated/deleted
/// - ProcessedTextCache when Message entities are deleted
@MainActor
final class CacheCoordinator {
    static let shared = CacheCoordinator()

    struct CacheInvalidationAccountContext: Sendable {
        fileprivate let coordinatorGeneration: UInt64
        let htmlContent: HTMLContentAccountGeneration
    }

    private struct AccountScopedSaveNotification {
        let notification: Notification
        let htmlContentGeneration: HTMLContentAccountGeneration
    }

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private var invalidationTasks: [UUID: Task<Void, Never>] = [:]

    struct CacheInvalidationPlan: Sendable {
        struct DeletedHTMLArtifact: Sendable, Hashable {
            let messageId: String
            let bodyStorageURI: String?
        }

        struct AttachmentIdentity: Sendable, Hashable {
            let messageId: String?
            let attachmentId: String
        }

        var personEmailsToInvalidate: Set<String> = []
        var messageIdsToInvalidate: Set<String> = []
        var deletedHTMLArtifacts: Set<DeletedHTMLArtifact> = []
        var attachmentPathsToDelete: Set<String> = []
        var attachmentIdentitiesToInvalidate: Set<AttachmentIdentity> = []
        var shouldClearPersonCache = false
    }

    init() {}

    /// Starts listening for Core Data changes. Call once at app startup.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            // Capture the file-store epoch on the posting context's queue. If
            // delivery to main is delayed across sign-out/reopen, this token
            // still identifies the account that produced the save.
            .compactMap { notification -> AccountScopedSaveNotification? in
                guard let generation = HTMLContentHandler.shared.captureAccountGeneration() else {
                    return nil
                }
                return AccountScopedSaveNotification(
                    notification: notification,
                    htmlContentGeneration: generation
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] capturedNotification in
                self?.handleContextDidSave(capturedNotification)
            }
            .store(in: &cancellables)

        Log.debug("CacheCoordinator started", category: .coreData)
    }

    /// Stops listening for Core Data changes.
    func stop() {
        cancellables.removeAll()
        isStarted = false
    }

    /// Retires queued invalidation work before account-scoped stores are
    /// cleared. Delayed context callbacks keep their old epoch and are rejected
    /// even if they arrive after a later account reopens.
    func closeAccountWorkAndAwait() async {
        acceptsAccountWork = false
        accountGeneration &+= 1
        let activeTasks = Array(invalidationTasks.values)
        activeTasks.forEach { $0.cancel() }
        for task in activeTasks {
            await task.value
        }
    }

    func reopenAccountWork() {
        accountGeneration &+= 1
        acceptsAccountWork = true
    }

    func captureInvalidationAccountContext() -> CacheInvalidationAccountContext? {
        guard let htmlGeneration = HTMLContentHandler.shared.captureAccountGeneration() else {
            return nil
        }
        return captureInvalidationAccountContext(htmlGeneration: htmlGeneration)
    }

    private func captureInvalidationAccountContext(
        htmlGeneration: HTMLContentAccountGeneration
    ) -> CacheInvalidationAccountContext? {
        guard acceptsAccountWork,
              HTMLContentHandler.shared.isAccountGenerationCurrent(htmlGeneration) else {
            return nil
        }
        return CacheInvalidationAccountContext(
            coordinatorGeneration: accountGeneration,
            htmlContent: htmlGeneration
        )
    }

    private func isAccountContextCurrent(_ context: CacheInvalidationAccountContext) -> Bool {
        acceptsAccountWork &&
            context.coordinatorGeneration == accountGeneration &&
            HTMLContentHandler.shared.isAccountGenerationCurrent(context.htmlContent)
    }

    private func handleContextDidSave(_ capturedNotification: AccountScopedSaveNotification) {
        let notification = capturedNotification.notification
        guard let sourceContext = notification.object as? NSManagedObjectContext else { return }

        let updatedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        let updatedObjectIDs = (notification.userInfo?[NSUpdatedObjectIDsKey] as? Set<NSManagedObjectID>) ??
            Set(updatedObjects.map(\.objectID))
        let deletedObjectIDs = (notification.userInfo?[NSDeletedObjectIDsKey] as? Set<NSManagedObjectID>) ??
            Set(deletedObjects.map(\.objectID))

        guard !updatedObjectIDs.isEmpty || !deletedObjectIDs.isEmpty else { return }
        guard let accountContext = captureInvalidationAccountContext(
            htmlGeneration: capturedNotification.htmlContentGeneration
        ) else { return }

        sourceContext.perform { [weak self] in
            let localPlan = CacheCoordinator.computeInvalidationPlan(
                updatedObjectIDs: updatedObjectIDs,
                deletedObjectIDs: deletedObjectIDs,
                in: sourceContext
            )

            Task { @MainActor [weak self] in
                self?.applyInvalidationPlan(localPlan, accountContext: accountContext)
            }
        }
    }

    /// Computes the cache-invalidation plan for a set of changed Core Data object IDs.
    ///
    /// Pure and side-effect-free: it inspects the changed managed objects and
    /// decides which caches need invalidating, returning the decision as a
    /// `CacheInvalidationPlan`. It performs no invalidation itself — that is the
    /// job of `applyInvalidationPlan(_:)`.
    ///
    /// Declared `nonisolated` so it can run on the source context's queue (where
    /// these managed objects are safe to read), and so the invalidation contract
    /// can be unit-tested directly without driving the global
    /// `NSManagedObjectContextDidSave` notification and async-apply path.
    ///
    /// - Note: Reads managed-object values via KVC defensively because deleted
    ///   objects can fault and lose their property values.
    nonisolated static func computeInvalidationPlan(
        updatedObjectIDs: Set<NSManagedObjectID>,
        deletedObjectIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) -> CacheInvalidationPlan {
        var plan = CacheInvalidationPlan()

        // Access managed object values on the context's queue to avoid cross-queue reads.
        for objectID in updatedObjectIDs.union(deletedObjectIDs) {
            let object = context.object(with: objectID)
            if let person = object as? Person {
                if let email = person.value(forKey: "email") as? String, !email.isEmpty {
                    plan.personEmailsToInvalidate.insert(email)
                } else {
                    plan.shouldClearPersonCache = true
                }
                continue
            }

            if deletedObjectIDs.contains(objectID),
               let message = object as? Message,
               let messageId = message.value(forKey: "id") as? String,
               !messageId.isEmpty {
                plan.messageIdsToInvalidate.insert(messageId)
                plan.deletedHTMLArtifacts.insert(
                    CacheInvalidationPlan.DeletedHTMLArtifact(
                        messageId: messageId,
                        bodyStorageURI: message.value(forKey: "bodyStorageURI") as? String
                    )
                )

                if let attachments = message.value(forKey: "attachments") as? Set<NSManagedObject> {
                    for attachment in attachments {
                        if let localURL = attachment.value(forKey: "localURL") as? String, !localURL.isEmpty {
                            plan.attachmentPathsToDelete.insert(localURL)
                        }
                        if let previewURL = attachment.value(forKey: "previewURL") as? String, !previewURL.isEmpty {
                            plan.attachmentPathsToDelete.insert(previewURL)
                        }
                        if let attachmentId = attachment.value(forKey: "id") as? String, !attachmentId.isEmpty {
                            plan.attachmentIdentitiesToInvalidate.insert(
                                CacheInvalidationPlan.AttachmentIdentity(
                                    messageId: messageId,
                                    attachmentId: attachmentId
                                )
                            )
                        }
                    }
                }
                continue
            }

            if deletedObjectIDs.contains(objectID),
               let attachment = object as? Attachment {
                if let localURL = attachment.value(forKey: "localURL") as? String, !localURL.isEmpty {
                    plan.attachmentPathsToDelete.insert(localURL)
                }
                if let previewURL = attachment.value(forKey: "previewURL") as? String, !previewURL.isEmpty {
                    plan.attachmentPathsToDelete.insert(previewURL)
                }
                if let attachmentId = attachment.value(forKey: "id") as? String, !attachmentId.isEmpty {
                    let messageId = (attachment.value(forKey: "message") as? Message)?
                        .value(forKey: "id") as? String
                    plan.attachmentIdentitiesToInvalidate.insert(
                        CacheInvalidationPlan.AttachmentIdentity(
                            messageId: messageId,
                            attachmentId: attachmentId
                        )
                    )
                }
            }
        }

        return plan
    }

    func applyInvalidationPlan(
        _ plan: CacheInvalidationPlan,
        accountContext: CacheInvalidationAccountContext
    ) {
        guard isAccountContextCurrent(accountContext) else { return }

        let shouldProcessDeletedArtifacts =
            !plan.messageIdsToInvalidate.isEmpty ||
            !plan.deletedHTMLArtifacts.isEmpty ||
            !plan.attachmentPathsToDelete.isEmpty ||
            !plan.attachmentIdentitiesToInvalidate.isEmpty

        let needsAsyncInvalidation = plan.shouldClearPersonCache ||
            !plan.personEmailsToInvalidate.isEmpty ||
            shouldProcessDeletedArtifacts
        if needsAsyncInvalidation {
            enqueueInvalidation(plan, accountContext: accountContext)
        }

        if !plan.messageIdsToInvalidate.isEmpty {
            Log.debug("Queued invalidation for \(plan.messageIdsToInvalidate.count) processed text cache entries", category: .coreData)
        }

        if !plan.attachmentPathsToDelete.isEmpty || !plan.attachmentIdentitiesToInvalidate.isEmpty {
            Log.debug(
                "Queued cleanup for \(plan.attachmentPathsToDelete.count) attachment files and \(plan.attachmentIdentitiesToInvalidate.count) attachment cache entries",
                category: .coreData
            )
        }
    }

    private func enqueueInvalidation(
        _ plan: CacheInvalidationPlan,
        accountContext: CacheInvalidationAccountContext
    ) {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.invalidationTasks.removeValue(forKey: taskID) }
            await self.performAsyncInvalidation(plan, accountContext: accountContext)
        }
        invalidationTasks[taskID] = task
    }

    private func performAsyncInvalidation(
        _ plan: CacheInvalidationPlan,
        accountContext: CacheInvalidationAccountContext
    ) async {
        guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }

        if plan.shouldClearPersonCache {
            await PersonCache.shared.clearCache()
        } else {
            for email in plan.personEmailsToInvalidate {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await PersonCache.shared.invalidateEntry(for: email)
            }
        }

        guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }

        let needsMessageInvalidation =
            !plan.messageIdsToInvalidate.isEmpty || !plan.deletedHTMLArtifacts.isEmpty
        let processedTextGeneration: ProcessedTextCacheAccountGeneration?
        let htmlInvalidationContext: HTMLContentInvalidationAccountContext?
        if needsMessageInvalidation {
            processedTextGeneration = await ProcessedTextCache.shared.captureAccountGeneration()
            htmlInvalidationContext = await HTMLContentLoader.shared.captureInvalidationAccountContext(
                expectedAccountGeneration: accountContext.htmlContent
            )
            guard processedTextGeneration != nil,
                  htmlInvalidationContext != nil,
                  !Task.isCancelled,
                  isAccountContextCurrent(accountContext) else {
                return
            }
        } else {
            processedTextGeneration = nil
            htmlInvalidationContext = nil
        }

        let needsAttachmentInvalidation =
            !plan.attachmentPathsToDelete.isEmpty || !plan.attachmentIdentitiesToInvalidate.isEmpty
        let attachmentGeneration: AttachmentCacheAccountGeneration?
        if needsAttachmentInvalidation {
            attachmentGeneration = await AttachmentCacheActor.shared.captureAccountGeneration()
            guard attachmentGeneration != nil,
                  !Task.isCancelled,
                  isAccountContextCurrent(accountContext) else {
                return
            }
        } else {
            attachmentGeneration = nil
        }

        if let processedTextGeneration, let htmlInvalidationContext {
            for messageId in plan.messageIdsToInvalidate {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await ProcessedTextCache.shared.invalidate(
                    messageId: messageId,
                    expectedAccountGeneration: processedTextGeneration,
                    invalidatesRenderedMessage: false
                )
                await HTMLContentLoader.shared.invalidateContent(
                    messageId: messageId,
                    accountContext: htmlInvalidationContext
                )
            }

            for artifact in plan.deletedHTMLArtifacts {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                HTMLContentHandler.shared.deleteHTML(
                    for: artifact.messageId,
                    bodyStorageURI: artifact.bodyStorageURI,
                    expectedGeneration: accountContext.htmlContent
                )
            }
        }

        if let attachmentGeneration {
            for relativePath in plan.attachmentPathsToDelete {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await AttachmentCacheActor.shared.deleteFile(
                    at: relativePath,
                    expectedAccountGeneration: attachmentGeneration
                )
            }

            for attachmentIdentity in plan.attachmentIdentitiesToInvalidate {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await AttachmentCacheActor.shared.removeFromCache(
                    messageId: attachmentIdentity.messageId,
                    attachmentId: attachmentIdentity.attachmentId,
                    expectedAccountGeneration: attachmentGeneration
                )
            }
        }
    }
}
