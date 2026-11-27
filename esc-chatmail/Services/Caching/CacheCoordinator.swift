import Foundation
import CoreData
import Combine

/// Coordinates cache invalidation across multiple caches when Core Data changes.
///
/// Listens for NSManagedObjectContextDidSave notifications and invalidates
/// relevant caches to prevent stale data.
///
/// ## Usage
/// Started once per process by `AppStartupBootstrap`'s process-services
/// operation, after the store has loaded and before authentication is
/// restored, never from a view and never in the unit-test host (where it
/// would hear every test stack's save).
///
/// The coordinator automatically invalidates:
/// - PersonCache when Person entities are updated/deleted
/// - HTMLContentLoader's derived-content caches (including RenderedMessageCache)
///   when Message entities are deleted
@MainActor
final class CacheCoordinator {
    static let shared = CacheCoordinator()

    struct CacheInvalidationAccountContext: Sendable {
        fileprivate let coordinatorGeneration: UInt64
        let htmlContent: HTMLContentAccountGeneration
    }

    /// What one save asks of the caches, with the account that made it. Built on the
    /// posting context's queue and made of values only: no managed object and no
    /// notification leaves that queue.
    struct AccountScopedSavePlan: Sendable {
        let plan: CacheInvalidationPlan
        let htmlContentGeneration: HTMLContentAccountGeneration
    }

    /// The two removers of the files a deleted row leaves. Both run off the main actor and
    /// both ask the store before they remove anything; a test puts in its own.
    struct FileReclamation: Sendable {
        /// Removes the body files of deleted messages (`HTMLContentHandler.deleteHTML(forDeleted:…)`).
        var deleteMessageBodies: @Sendable (
            _ bodies: [DeletedMessageBody],
            _ deletedAt: Date,
            _ generation: HTMLContentAccountGeneration
        ) -> Void
        /// Removes the files of deleted attachments (`AttachmentCacheActor.deleteFiles(at:…)`).
        var deleteAttachmentFiles: @Sendable (
            _ relativePaths: [String],
            _ deletedAt: Date,
            _ generation: AttachmentCacheAccountGeneration
        ) async -> Void

        static let production = FileReclamation.asking {
            CoreDataStack.shared.newBackgroundContext()
        }

        /// The app's removers, asking a store for its rows through a context of
        /// `makeContext`'s. A fresh context sees saved rows only, which is what is asked.
        static func asking(
            _ makeContext: @escaping @Sendable () -> NSManagedObjectContext
        ) -> FileReclamation {
            FileReclamation(
                deleteMessageBodies: { bodies, deletedAt, generation in
                    let context = makeContext()
                    HTMLContentHandler.shared.deleteHTML(
                        forDeleted: bodies,
                        deletedAt: deletedAt,
                        expectedGeneration: generation,
                        liveMessageIDs: { ids in
                            try DeletedRowFileReclamation.liveMessageIDs(among: ids, in: context)
                        }
                    )
                },
                deleteAttachmentFiles: { relativePaths, deletedAt, generation in
                    let context = makeContext()
                    await AttachmentCacheActor.shared.deleteFiles(
                        at: relativePaths,
                        deletedAt: deletedAt,
                        expectedAccountGeneration: generation,
                        referencedPaths: { paths in
                            try DeletedRowFileReclamation.referencedAttachmentPaths(among: paths, in: context)
                        }
                    )
                }
            )
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private var invalidationTasks: [UUID: Task<Void, Never>] = [:]
    private let fileReclamation: FileReclamation

    struct CacheInvalidationPlan: Sendable {
        typealias DeletedHTMLArtifact = DeletedMessageBody

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
        /// When the save that deleted the rows was posted. A file written after this is not
        /// the deleted row's: the same message or attachment was stored again, and the
        /// removers leave it (`DeletedRowFileReclamation.wasWrittenAfter`).
        var deletedAt = Date()

        var isEmpty: Bool {
            personEmailsToInvalidate.isEmpty &&
                messageIdsToInvalidate.isEmpty &&
                deletedHTMLArtifacts.isEmpty &&
                attachmentPathsToDelete.isEmpty &&
                attachmentIdentitiesToInvalidate.isEmpty &&
                !shouldClearPersonCache
        }
    }

    init(fileReclamation: FileReclamation = .production) {
        self.fileReclamation = fileReclamation
    }

    /// Starts listening for Core Data changes. Call once at app startup.
    ///
    /// - Parameter context: Only this context's saves are heard. The app hears every
    ///   context's; a test names its own, so that no other save in the process reaches the
    ///   coordinator it started.
    func start(observing context: NSManagedObjectContext? = nil) {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context)
            // Everything a save tells the caches is read here, on the posting context's
            // queue, inside the save. Two things are only available here. The file-store
            // epoch: if delivery to main is delayed across sign-out/reopen, this token
            // still identifies the account that produced the save. And the deleted rows'
            // values: the instances under `NSDeletedObjectsKey` still hold them, and
            // anything resolved from their IDs later is a tombstone with a nil `id`, nil
            // paths and no attachments, so a plan built after the hop was empty for every
            // delete and no file of a deleted message was ever removed.
            .compactMap { notification -> AccountScopedSavePlan? in
                CacheCoordinator.savePlan(forSave: notification) {
                    HTMLContentHandler.shared.captureAccountGeneration()
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] savePlan in
                self?.handleSavePlan(savePlan)
            }
            .store(in: &cancellables)

        Log.debug("CacheCoordinator started", category: .coreData)
    }

    /// What one save asks of the caches, with the account that made it, or nil where it
    /// asks nothing. The plan is built first and the generation captured only for a plan
    /// that is not empty: the capture takes the HTML boundary's lock, which every body
    /// read and write and every deletion chunk holds, and until 2026-11-27 every save in
    /// the process took it before knowing it had nothing to invalidate, a main-queue save
    /// of an optimistic row included (architecture review 2026-11,
    /// gap-change-propagation-pipeline#5). Both still happen here, on the posting
    /// context's queue inside the save (CLAUDE.md's post-time capture rule): the
    /// generation names the account that made the save even when delivery to main is
    /// delayed across a sign-out and reopen, and the deleted rows' values exist only here.
    nonisolated static func savePlan(
        forSave notification: Notification,
        captureGeneration: () -> HTMLContentAccountGeneration?
    ) -> AccountScopedSavePlan? {
        let plan = invalidationPlan(forSave: notification)
        guard !plan.isEmpty, let generation = captureGeneration() else { return nil }
        return AccountScopedSavePlan(plan: plan, htmlContentGeneration: generation)
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

    private func handleSavePlan(_ savePlan: AccountScopedSavePlan) {
        guard let accountContext = captureInvalidationAccountContext(
            htmlGeneration: savePlan.htmlContentGeneration
        ) else { return }
        applyInvalidationPlan(savePlan.plan, accountContext: accountContext)
    }

    /// The plan for one `NSManagedObjectContextDidSave` notification. Call it only while the
    /// notification is being posted, on the queue that posts it: it reads the notification's
    /// managed objects.
    nonisolated static func invalidationPlan(
        forSave notification: Notification,
        deletedAt: Date = Date()
    ) -> CacheInvalidationPlan {
        let updatedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        guard !updatedObjects.isEmpty || !deletedObjects.isEmpty else {
            return CacheInvalidationPlan(deletedAt: deletedAt)
        }
        return computeInvalidationPlan(
            updatedObjects: updatedObjects,
            deletedObjects: deletedObjects,
            deletedAt: deletedAt
        )
    }

    /// Computes the cache-invalidation plan for a set of changed managed objects.
    ///
    /// Pure and side-effect-free: it reads the objects it is given and decides which caches
    /// need invalidating and which files a deleted row leaves, returning the decision as a
    /// `CacheInvalidationPlan`. It performs no invalidation itself — that is the job of
    /// `applyInvalidationPlan(_:)`.
    ///
    /// It takes the objects themselves, never their IDs, and must run on their context's
    /// queue. In a save notification a deleted object still holds its attributes, while its
    /// relationships are already cut: a deleted message's `attachments` is empty there, and
    /// each attachment is in the deleted set itself, which is where its paths are read. The
    /// read through `attachments` stays for a caller that asks before the save.
    ///
    /// Nothing here fires a fault. A deleted row has nothing to fulfil one from, and a
    /// fault fired inside a save notification would mark the object deleted in its context.
    nonisolated static func computeInvalidationPlan(
        updatedObjects: Set<NSManagedObject>,
        deletedObjects: Set<NSManagedObject>,
        deletedAt: Date = Date()
    ) -> CacheInvalidationPlan {
        var plan = CacheInvalidationPlan(deletedAt: deletedAt)
        // The attachment IDs that have an identity in the plan, whichever message it names.
        // Kept beside the plan so the check below is a lookup: inside a save notification
        // every cascade-deleted attachment has lost its message and asks it, and a scan of
        // the identities there made a delete of n attachments n² comparisons inside the save.
        var identifiedAttachmentIDs: Set<String> = []

        for object in updatedObjects {
            guard let person = object as? Person else { continue }
            if let email = storedString("email", of: person) {
                plan.personEmailsToInvalidate.insert(email)
            } else {
                plan.shouldClearPersonCache = true
            }
        }

        for object in deletedObjects {
            if let person = object as? Person {
                // One entry, never the whole cache: a deleted Person read after the save
                // had a nil email, and every delete cleared the cache. One whose email
                // cannot be read here was never cached under an address.
                if let email = storedString("email", of: person) {
                    plan.personEmailsToInvalidate.insert(email)
                }
                continue
            }

            if let message = object as? Message {
                guard let messageId = storedString("id", of: message) else { continue }
                plan.messageIdsToInvalidate.insert(messageId)
                plan.deletedHTMLArtifacts.insert(
                    DeletedMessageBody(
                        messageId: messageId,
                        bodyStorageURI: storedString("bodyStorageURI", of: message)
                    )
                )
                if !message.isFault,
                   !message.hasFault(forRelationshipNamed: "attachments"),
                   let attachments = message.value(forKey: "attachments") as? Set<NSManagedObject> {
                    for attachment in attachments {
                        collectDeletedAttachment(
                            attachment,
                            messageId: messageId,
                            into: &plan,
                            identifiedAttachmentIDs: &identifiedAttachmentIDs
                        )
                    }
                }
                continue
            }

            if let attachment = object as? Attachment {
                collectDeletedAttachment(
                    attachment,
                    messageId: messageId(ofDeleted: attachment),
                    into: &plan,
                    identifiedAttachmentIDs: &identifiedAttachmentIDs
                )
            }
        }

        return plan
    }

    /// - Parameter identifiedAttachmentIDs: The attachment IDs `plan` already has an identity
    ///   for, with or without a message. Every insertion of an identity adds its ID here, and
    ///   removing the nil-message identity never takes one out: it is replaced, in the same
    ///   call, by the message's own.
    private nonisolated static func collectDeletedAttachment(
        _ attachment: NSManagedObject,
        messageId: String?,
        into plan: inout CacheInvalidationPlan,
        identifiedAttachmentIDs: inout Set<String>
    ) {
        if let localURL = storedString("localURL", of: attachment) {
            plan.attachmentPathsToDelete.insert(localURL)
        }
        if let previewURL = storedString("previewURL", of: attachment) {
            plan.attachmentPathsToDelete.insert(previewURL)
        }
        guard let attachmentId = storedString("id", of: attachment) else { return }
        if let messageId {
            // The message's own identity is the exact one. Drop the wider nil-message
            // entry the same attachment may have been given from the deleted set, where
            // its message is no longer attached.
            plan.attachmentIdentitiesToInvalidate.remove(
                CacheInvalidationPlan.AttachmentIdentity(messageId: nil, attachmentId: attachmentId)
            )
            plan.attachmentIdentitiesToInvalidate.insert(
                CacheInvalidationPlan.AttachmentIdentity(messageId: messageId, attachmentId: attachmentId)
            )
            identifiedAttachmentIDs.insert(attachmentId)
        } else if identifiedAttachmentIDs.insert(attachmentId).inserted {
            // A nil message evicts every message's entry for this attachment ID
            // (`AttachmentCacheActor.removeFromCache`): wider than needed, and only a cache.
            plan.attachmentIdentitiesToInvalidate.insert(
                CacheInvalidationPlan.AttachmentIdentity(messageId: nil, attachmentId: attachmentId)
            )
        }
    }

    /// The ID of the message a deleted attachment belonged to, where the attachment still
    /// names it and the message's values are in memory.
    private nonisolated static func messageId(ofDeleted attachment: NSManagedObject) -> String? {
        guard !attachment.isFault,
              let message = attachment.value(forKey: "message") as? NSManagedObject else {
            return nil
        }
        return storedString("id", of: message)
    }

    /// A non-empty string attribute of `object`, or nil where the object is a fault.
    private nonisolated static func storedString(_ key: String, of object: NSManagedObject) -> String? {
        guard !object.isFault,
              let value = object.value(forKey: key) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
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
            Log.debug("Queued invalidation for \(plan.messageIdsToInvalidate.count) message content cache entries", category: .coreData)
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
        let htmlInvalidationContext: HTMLContentInvalidationAccountContext?
        if needsMessageInvalidation {
            htmlInvalidationContext = await HTMLContentLoader.shared.captureInvalidationAccountContext(
                expectedAccountGeneration: accountContext.htmlContent
            )
            guard htmlInvalidationContext != nil,
                  !Task.isCancelled,
                  isAccountContextCurrent(accountContext) else {
                return
            }
        } else {
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

        if let htmlInvalidationContext {
            for messageId in plan.messageIdsToInvalidate {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await HTMLContentLoader.shared.invalidateContent(
                    messageId: messageId,
                    accountContext: htmlInvalidationContext
                )
            }

            if !plan.deletedHTMLArtifacts.isEmpty {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await deleteMessageBodiesOffMainActor(
                    Array(plan.deletedHTMLArtifacts),
                    deletedAt: plan.deletedAt,
                    generation: accountContext.htmlContent
                )
            }
        }

        if let attachmentGeneration {
            if !plan.attachmentPathsToDelete.isEmpty {
                guard !Task.isCancelled, isAccountContextCurrent(accountContext) else { return }
                await fileReclamation.deleteAttachmentFiles(
                    Array(plan.attachmentPathsToDelete),
                    plan.deletedAt,
                    attachmentGeneration
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

    /// Removes the deleted messages' body files in a task of its own, never on the main
    /// actor: a purge of thousands of messages is thousands of unlinks under the HTML
    /// boundary's lock. The invalidation task that calls this waits for it, cancelled or
    /// not, so `closeAccountWorkAndAwait` still drains the removal before storage is cleared.
    private func deleteMessageBodiesOffMainActor(
        _ bodies: [DeletedMessageBody],
        deletedAt: Date,
        generation: HTMLContentAccountGeneration
    ) async {
        let deleteMessageBodies = fileReclamation.deleteMessageBodies
        let removal = Task.detached(priority: .utility) {
            deleteMessageBodies(bodies, deletedAt, generation)
        }
        await withTaskCancellationHandler {
            await removal.value
        } onCancel: {
            removal.cancel()
        }
    }
}
