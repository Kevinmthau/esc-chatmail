import SwiftUI
import CoreData
import Combine

// MARK: - Virtual Scroll State
@MainActor
final class VirtualScrollState: ObservableObject {
    @Published var visibleMessages: [Message] = []
    @Published var totalMessageCount = 0
    @Published var scrollPosition: Int = 0
    @Published var isLoadingMore = false
    @Published var placeholderIndices: Set<Int> = []

    private let configuration: VirtualScrollConfiguration
    private var messageWindow: MessageWindow?
    private let conversationId: String
    private let coreDataStack = CoreDataStack.shared
    private var cancellables = Set<AnyCancellable>()

    // Task tracking to prevent orphaned tasks during rapid scrolling
    private var loadInitialTask: Task<Void, Never>?
    private var loadWindowTask: Task<Void, Never>?
    private var preloadNextTask: Task<Void, Never>?
    private var preloadPreviousTask: Task<Void, Never>?

    init(conversationId: String, configuration: VirtualScrollConfiguration = .default) {
        self.conversationId = conversationId
        self.configuration = configuration
        loadInitialMessages()
    }

    func scrollTo(index: Int) {
        // Skip small position changes to avoid excessive updates during scroll
        // This prevents 10+ calls per scroll when each visible message fires onAppear
        guard abs(index - scrollPosition) > 2 else { return }

        scrollPosition = index
        updateVisibleMessages()
        preloadIfNeeded()
    }

    private func loadInitialMessages() {
        isLoadingMore = true

        loadInitialTask?.cancel()
        loadInitialTask = Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, total) = await loadMessages(
                range: 0..<configuration.visibleItemCount,
                in: context
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.visibleMessages = messages
                self.totalMessageCount = total
                self.messageWindow = MessageWindow(
                    startIndex: 0,
                    endIndex: min(configuration.visibleItemCount, total),
                    messages: messages,
                    isLoading: false
                )
                self.isLoadingMore = false
            }
        }
    }

    private func updateVisibleMessages() {
        guard let window = messageWindow else { return }

        let startIndex = max(0, scrollPosition - configuration.bufferSize)
        let endIndex = min(totalMessageCount, scrollPosition + configuration.visibleItemCount + configuration.bufferSize)

        if window.contains(index: startIndex) && window.contains(index: endIndex - 1) {
            // Current window is sufficient
            let windowStart = startIndex - window.startIndex
            let windowEnd = endIndex - window.startIndex
            visibleMessages = Array(window.messages[windowStart..<windowEnd])
        } else {
            // Need to load new window
            loadWindow(startIndex: startIndex, endIndex: endIndex)
        }
    }

    private func loadWindow(startIndex: Int, endIndex: Int) {
        isLoadingMore = true

        // Show placeholders while loading
        placeholderIndices = Set(startIndex..<endIndex)

        loadWindowTask?.cancel()
        loadWindowTask = Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, _) = await loadMessages(
                range: startIndex..<endIndex,
                in: context
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.messageWindow = MessageWindow(
                    startIndex: startIndex,
                    endIndex: endIndex,
                    messages: messages,
                    isLoading: false
                )
                self.visibleMessages = messages
                self.placeholderIndices.removeAll()
                self.isLoadingMore = false
            }
        }
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

        preloadNextTask?.cancel()
        preloadNextTask = Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, _) = await loadMessages(
                range: startIndex..<endIndex,
                in: context
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard var currentWindow = self.messageWindow else { return }
                currentWindow.messages.append(contentsOf: messages)
                currentWindow = MessageWindow(
                    startIndex: currentWindow.startIndex,
                    endIndex: endIndex,
                    messages: currentWindow.messages,
                    isLoading: false
                )
                self.messageWindow = currentWindow
            }
        }
    }

    private func preloadPrevious() {
        guard let window = messageWindow,
              window.startIndex > 0 else { return }

        let endIndex = window.startIndex
        let startIndex = max(0, endIndex - configuration.pageSize)

        preloadPreviousTask?.cancel()
        preloadPreviousTask = Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, _) = await loadMessages(
                range: startIndex..<endIndex,
                in: context
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard var currentWindow = self.messageWindow else { return }
                currentWindow.messages = messages + currentWindow.messages
                currentWindow = MessageWindow(
                    startIndex: startIndex,
                    endIndex: currentWindow.endIndex,
                    messages: currentWindow.messages,
                    isLoading: false
                )
                self.messageWindow = currentWindow
            }
        }
    }

    /// Cancels all pending tasks when the scroll state is no longer needed
    func cleanup() {
        loadInitialTask?.cancel()
        loadWindowTask?.cancel()
        preloadNextTask?.cancel()
        preloadPreviousTask?.cancel()

        loadInitialTask = nil
        loadWindowTask = nil
        preloadNextTask = nil
        preloadPreviousTask = nil
    }

    private func loadMessages(range: Range<Int>, in context: NSManagedObjectContext) async -> ([Message], Int) {
        await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", self.conversationId)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
            request.fetchOffset = range.lowerBound
            request.fetchLimit = range.count
            request.fetchBatchSize = 20

            let messages = (try? context.fetch(request)) ?? []

            // Get total count using efficient count() method instead of a full fetch
            let countRequest = Message.fetchRequest()
            countRequest.predicate = request.predicate
            let total = (try? context.count(for: countRequest)) ?? 0

            return (messages, total)
        }
    }
}
