import SwiftUI
import CoreData
import Combine

// MARK: - Virtual Scroll Configuration
struct VirtualScrollConfiguration {
    let visibleItemCount: Int
    let bufferSize: Int
    let pageSize: Int
    let preloadThreshold: Int

    static let `default` = VirtualScrollConfiguration(
        visibleItemCount: 20,
        bufferSize: 10,
        pageSize: 50,
        preloadThreshold: 5
    )
}

// MARK: - Message Window
struct MessageWindow {
    let startIndex: Int
    let endIndex: Int
    var messages: [Message]
    var isLoading: Bool

    var range: Range<Int> {
        startIndex..<endIndex
    }

    func contains(index: Int) -> Bool {
        range.contains(index)
    }
}

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

// MARK: - Virtual Scroll Chat View
struct VirtualScrollChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var scrollState: VirtualScrollState
    @StateObject private var cache = ConversationCache.shared
    @State private var scrollViewReader: ScrollViewProxy?

    init(conversation: Conversation) {
        self.conversation = conversation
        self._scrollState = StateObject(
            wrappedValue: VirtualScrollState(conversationId: conversation.id.uuidString)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(scrollState.visibleMessages.enumerated()), id: \.element.id) { index, message in
                        Group {
                            if scrollState.placeholderIndices.contains(index) {
                                MessageSkeletonView()
                            } else {
                                OptimizedMessageBubble(
                                    message: message,
                                    conversation: conversation
                                )
                            }
                        }
                        .id(index)
                        .onAppear {
                            scrollState.scrollTo(index: index)
                        }
                    }

                    if scrollState.isLoadingMore {
                        ProgressView()
                            .padding()
                    }
                }
                .padding(.horizontal)
            }
            .onAppear {
                scrollViewReader = proxy
                // Scroll to bottom on appear
                if let lastIndex = scrollState.visibleMessages.indices.last {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Optimized Message Bubble
struct OptimizedMessageBubble: View {
    let message: Message
    let conversation: Conversation
    @State private var isExpanded = false
    @State private var htmlLoaded = false

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            // Sender info
            if !message.isFromMe {
                Text(message.senderNameValue ?? "Unknown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Message content
            messageContent
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .cornerRadius(16)

            // Timestamp
            Text(message.internalDate.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageContent: some View {
        if let snippet = message.cleanedSnippet ?? message.snippet {
            Text(snippet)
                .foregroundColor(message.isFromMe ? .white : .primary)
                .lineLimit(isExpanded ? nil : 3)
                .onTapGesture {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }
        }

        if message.hasAttachments {
            let attachmentCount = message.typedAttachments.count
            AttachmentIndicator(count: attachmentCount)
        }
    }

    private var bubbleBackground: some View {
        Group {
            if message.isFromMe {
                Color.blue
            } else {
                Color(.systemGray5)
            }
        }
    }
}

// MARK: - Message Skeleton View
struct MessageSkeletonView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sender skeleton
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 80, height: 12)

            // Message skeleton
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 16)
                        .frame(maxWidth: .random(in: 150...250))
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)

            // Timestamp skeleton
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 60, height: 10)
        }
        .opacity(isAnimating ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 1.0).repeatForever(), value: isAnimating)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Attachment Indicator
struct AttachmentIndicator: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.caption)
            Text("\(count) attachment\(count == 1 ? "" : "s")")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
    }
}