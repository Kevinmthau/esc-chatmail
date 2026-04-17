import SwiftUI
import CoreData

// `NSManagedObjectID` is the cross-context token Core Data intends us to pass
// between queues, so this payload is safe to move across task boundaries.
struct VirtualScrollMessagePage: @unchecked Sendable {
    let messageIDs: [NSManagedObjectID]
    let totalCount: Int
}

// MARK: - Virtual Scroll State
@MainActor
final class VirtualScrollState: ObservableObject {
    enum InitialWindowPosition {
        case beginning
        case end
    }

    typealias MessagePageLoader = (
        _ conversationId: String,
        _ range: Range<Int>,
        _ context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage

    @Published var visibleMessages: [Message] = []
    @Published var totalMessageCount = 0
    @Published var scrollPosition: Int = 0
    @Published var isLoadingMore = false
    @Published var placeholderIndices: Set<Int> = []

    private let configuration: VirtualScrollConfiguration
    private let initialWindowPosition: InitialWindowPosition
    private var messageWindow: MessageWindow?
    private let conversationId: String
    private let viewContext: NSManagedObjectContext
    private let makeBackgroundContext: () -> NSManagedObjectContext
    private let pageLoader: MessagePageLoader

    // Cache only view-context messages for the current window. Background contexts
    // fetch IDs, and the UI never stores those background `Message` instances.
    private var resolvedMessagesByID: [NSManagedObjectID: Message] = [:]

    // Task tracking to prevent orphaned tasks during rapid scrolling
    private let taskManager = ViewModelTaskManager()

    init(
        conversationId: String,
        configuration: VirtualScrollConfiguration = .default,
        initialWindowPosition: InitialWindowPosition = .beginning
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.initialWindowPosition = initialWindowPosition
        self.viewContext = CoreDataStack.shared.viewContext
        self.makeBackgroundContext = { CoreDataStack.shared.newBackgroundContext() }
        self.pageLoader = VirtualScrollState.loadMessagePage
        loadInitialMessages()
    }

    init(
        conversationId: String,
        configuration: VirtualScrollConfiguration = .default,
        initialWindowPosition: InitialWindowPosition = .beginning,
        viewContext: NSManagedObjectContext,
        makeBackgroundContext: @escaping () -> NSManagedObjectContext,
        pageLoader: @escaping MessagePageLoader = VirtualScrollState.loadMessagePage,
        autoLoad: Bool = true
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.initialWindowPosition = initialWindowPosition
        self.viewContext = viewContext
        self.makeBackgroundContext = makeBackgroundContext
        self.pageLoader = pageLoader

        if autoLoad {
            loadInitialMessages()
        }
    }

    /// Notifies the scroll state that a message at the given index is now visible.
    /// Called from onAppear for each message in the LazyVStack.
    func markIndexVisible(_ index: Int) {
        // Skip small position changes to avoid excessive updates during scroll
        // This prevents 10+ calls per scroll when each visible message fires onAppear
        guard abs(index - scrollPosition) > 2 else { return }

        scrollPosition = index
        updateVisibleMessages()
        preloadIfNeeded()
    }

    var visibleRangeStartIndex: Int {
        messageWindow?.startIndex ?? 0
    }

    var isShowingLatestWindow: Bool {
        guard let messageWindow else { return false }
        return messageWindow.endIndex >= totalMessageCount
    }

    func absoluteIndex(forVisibleIndex index: Int) -> Int? {
        guard index >= 0, index < visibleMessages.count else {
            return nil
        }

        return visibleRangeStartIndex + index
    }

    private func loadInitialMessages() {
        isLoadingMore = true

        taskManager.run("loadInitial") { [weak self] in
            guard let self = self else { return }

            let initialRange = await self.initialMessageRange()
            let page = await self.pageLoader(
                self.conversationId,
                initialRange,
                self.makeBackgroundContext()
            )

            guard !Task.isCancelled else { return }

            let messages = await self.resolveMessagesOnViewContext(for: page.messageIDs)

            guard !Task.isCancelled else { return }

            let endIndex = initialRange.lowerBound + page.messageIDs.count
            let window = MessageWindow(
                startIndex: initialRange.lowerBound,
                endIndex: endIndex,
                messageIDs: page.messageIDs,
                isLoading: false
            )

            self.totalMessageCount = page.totalCount
            self.scrollPosition = initialRange.lowerBound
            self.setMessageWindow(window)
            self.visibleMessages = messages
            self.isLoadingMore = false
        }
    }

    func loadLatestWindowIfNeeded() async {
        guard !isShowingLatestWindow || visibleMessages.isEmpty else {
            return
        }

        await loadLatestWindow()
    }

    func loadLatestWindow() async {
        let totalCount = await loadTotalMessageCount()
        let startIndex = max(0, totalCount - configuration.visibleItemCount)
        await loadWindow(startIndex: startIndex, endIndex: totalCount)
        scrollPosition = max(startIndex, totalCount - 1)
    }

    private func updateVisibleMessages() {
        guard let window = messageWindow else { return }

        let startIndex = max(0, scrollPosition - configuration.bufferSize)
        let endIndex = min(totalMessageCount, scrollPosition + configuration.visibleItemCount + configuration.bufferSize)

        if window.contains(index: startIndex) && window.contains(index: endIndex - 1) {
            // Current window already covers the requested range.
            // Keep rendering the whole window so the user can continue scrolling
            // through the buffered messages without the view pruning rows away.
            visibleMessages = resolveCachedMessages(for: window.messageIDs)
        } else {
            // Need to load a new window.
            taskManager.run("loadWindow") { [weak self] in
                guard let self = self else { return }
                await self.loadWindow(startIndex: startIndex, endIndex: endIndex)
            }
        }
    }

    private func loadWindow(startIndex: Int, endIndex: Int) async {
        guard startIndex >= 0, endIndex >= startIndex else {
            return
        }

        isLoadingMore = true

        // Show placeholders while loading
        placeholderIndices = Set(startIndex..<endIndex)

        let page = await pageLoader(
            conversationId,
            startIndex..<endIndex,
            makeBackgroundContext()
        )

        guard !Task.isCancelled else { return }

        let messages = await resolveMessagesOnViewContext(for: page.messageIDs)

        guard !Task.isCancelled else { return }

        let loadedEndIndex = startIndex + page.messageIDs.count
        let window = MessageWindow(
            startIndex: startIndex,
            endIndex: loadedEndIndex,
            messageIDs: page.messageIDs,
            isLoading: false
        )

        totalMessageCount = page.totalCount
        setMessageWindow(window)
        visibleMessages = messages
        placeholderIndices.removeAll()
        isLoadingMore = false
    }

    private func initialMessageRange() async -> Range<Int> {
        switch initialWindowPosition {
        case .beginning:
            return 0..<configuration.visibleItemCount
        case .end:
            let totalCount = await loadTotalMessageCount()
            let startIndex = max(0, totalCount - configuration.visibleItemCount)
            return startIndex..<totalCount
        }
    }

    private func loadTotalMessageCount() async -> Int {
        let metadataPage = await pageLoader(
            conversationId,
            0..<0,
            makeBackgroundContext()
        )

        return metadataPage.totalCount
    }

    private func preloadIfNeeded() {
        guard let window = messageWindow else { return }

        let distanceToEnd = window.endIndex - scrollPosition
        if distanceToEnd < configuration.preloadThreshold {
            preloadNext()
        }

        let distanceToStart = scrollPosition - window.startIndex
        if distanceToStart < configuration.preloadThreshold {
            preloadPrevious()
        }
    }

    private func preloadNext() {
        guard let window = messageWindow,
              window.endIndex < totalMessageCount else { return }

        let startIndex = window.endIndex
        let endIndex = min(totalMessageCount, startIndex + configuration.pageSize)

        taskManager.run("preloadNext") { [weak self] in
            guard let self = self else { return }

            let page = await self.pageLoader(
                self.conversationId,
                startIndex..<endIndex,
                self.makeBackgroundContext()
            )

            guard !Task.isCancelled else { return }

            _ = await self.resolveMessagesOnViewContext(for: page.messageIDs)

            guard !Task.isCancelled else { return }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs.append(contentsOf: page.messageIDs)
            currentWindow = MessageWindow(
                startIndex: currentWindow.startIndex,
                endIndex: startIndex + page.messageIDs.count,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            )

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedMessages(for: currentWindow.messageIDs)
        }
    }

    private func preloadPrevious() {
        guard let window = messageWindow,
              window.startIndex > 0 else { return }

        let endIndex = window.startIndex
        let startIndex = max(0, endIndex - configuration.pageSize)

        taskManager.run("preloadPrevious") { [weak self] in
            guard let self = self else { return }

            let page = await self.pageLoader(
                self.conversationId,
                startIndex..<endIndex,
                self.makeBackgroundContext()
            )

            guard !Task.isCancelled else { return }

            _ = await self.resolveMessagesOnViewContext(for: page.messageIDs)

            guard !Task.isCancelled else { return }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs = page.messageIDs + currentWindow.messageIDs
            currentWindow = MessageWindow(
                startIndex: startIndex,
                endIndex: currentWindow.endIndex,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            )

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedMessages(for: currentWindow.messageIDs)
        }
    }

    /// Cancels all pending tasks when the scroll state is no longer needed
    func cleanup() {
        taskManager.cancelAll()
    }

    private func setMessageWindow(_ window: MessageWindow) {
        messageWindow = window

        let allowedIDs = Set(window.messageIDs)
        resolvedMessagesByID = resolvedMessagesByID.filter { allowedIDs.contains($0.key) }
    }

    // The original bug was caused by fetching `Message` instances in a background
    // context and then storing those managed objects on `@MainActor` state. We now
    // re-resolve background-fetched object IDs on the viewContext before caching or
    // publishing them so SwiftUI only ever sees main-context `Message` objects.
    private func resolveMessagesOnViewContext(for messageIDs: [NSManagedObjectID]) async -> [Message] {
        guard !messageIDs.isEmpty else { return [] }

        let resolvedMessages: [NSManagedObjectID: Message] = await viewContext.perform { [viewContext] in
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(format: "SELF IN %@", messageIDs)
            request.fetchBatchSize = messageIDs.count

            let fetchedMessages = (try? viewContext.fetch(request)) ?? []
            return Dictionary(
                uniqueKeysWithValues: fetchedMessages.compactMap { message in
                    guard !message.isDeleted else { return nil }
                    return (message.objectID, message)
                }
            )
        }

        for objectID in messageIDs {
            if let message = resolvedMessages[objectID] {
                resolvedMessagesByID[objectID] = message
            } else {
                resolvedMessagesByID.removeValue(forKey: objectID)
            }
        }

        return messageIDs.compactMap { resolvedMessages[$0] }
    }

    private func resolveCachedMessages(for messageIDs: [NSManagedObjectID]) -> [Message] {
        messageIDs.compactMap { objectID in
            if let cached = resolvedMessagesByID[objectID],
               cached.managedObjectContext === viewContext,
               !cached.isDeleted {
                return cached
            }

            do {
                guard let resolved = try viewContext.existingObject(with: objectID) as? Message,
                      !resolved.isDeleted else {
                    resolvedMessagesByID.removeValue(forKey: objectID)
                    return nil
                }

                resolvedMessagesByID[objectID] = resolved
                return resolved
            } catch {
                resolvedMessagesByID.removeValue(forKey: objectID)
                return nil
            }
        }
    }

    nonisolated static func loadMessagePage(
        conversationId: String,
        range: Range<Int>,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = NSPredicate(format: "conversation.id == %@", conversationUUID as CVarArg)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
            request.predicate = safePredicate
            request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: true)]
            request.fetchOffset = range.lowerBound
            request.fetchLimit = range.count
            request.fetchBatchSize = 20
            request.resultType = .managedObjectIDResultType

            let messageIDs = (try? context.fetch(request)) ?? []

            // Keep count() on the background context so window sizing stays cheap and
            // the main actor only resolves the IDs it actually needs to render.
            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            countRequest.predicate = safePredicate
            let totalCount = (try? context.count(for: countRequest)) ?? 0

            return VirtualScrollMessagePage(messageIDs: messageIDs, totalCount: totalCount)
        }
    }
}
