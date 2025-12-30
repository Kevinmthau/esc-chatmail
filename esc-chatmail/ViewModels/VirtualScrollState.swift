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

    init(conversationId: String, configuration: VirtualScrollConfiguration = .default) {
        self.conversationId = conversationId
        self.configuration = configuration
        loadInitialMessages()
    }

    func scrollTo(index: Int) {
        scrollPosition = index
        updateVisibleMessages()
        preloadIfNeeded()
    }

    private func loadInitialMessages() {
        isLoadingMore = true

        Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, total) = await loadMessages(
                range: 0..<configuration.visibleItemCount,
                in: context
            )

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

        Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, _) = await loadMessages(
                range: startIndex..<endIndex,
                in: context
            )

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

        Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, _) = await loadMessages(
                range: startIndex..<endIndex,
                in: context
            )

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

        Task {
            let context = coreDataStack.newBackgroundContext()
            let (messages, _) = await loadMessages(
                range: startIndex..<endIndex,
                in: context
            )

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

    private func loadMessages(range: Range<Int>, in context: NSManagedObjectContext) async -> ([Message], Int) {
        await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", self.conversationId)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
            request.fetchOffset = range.lowerBound
            request.fetchLimit = range.count
            request.fetchBatchSize = 20

            let messages = (try? context.fetch(request)) ?? []

            // Get total count
            let countRequest = NSFetchRequest<NSNumber>(entityName: "Message")
            countRequest.predicate = request.predicate
            countRequest.resultType = .countResultType
            let total = (try? context.fetch(countRequest).first?.intValue) ?? 0

            return (messages, total)
        }
    }
}
