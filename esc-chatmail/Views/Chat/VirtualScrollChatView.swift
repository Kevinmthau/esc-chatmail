import SwiftUI
import CoreData

// MARK: - Virtual Scroll Chat View
struct VirtualScrollChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var scrollState: VirtualScrollState
    @State private var scrollViewReader: ScrollViewProxy?
    @State private var fullEmailOpenSession: FullEmailOpenSession?
    private let chatDependencies: ChatDependencies
    private let fullEmailReaderCoordinator: FullEmailReaderCoordinator

    init(conversation: Conversation, chatDependencies: ChatDependencies) {
        self.conversation = conversation
        self.chatDependencies = chatDependencies
        self.fullEmailReaderCoordinator = FullEmailReaderCoordinator(
            fullEmailOpener: chatDependencies.fullEmailOpener
        )
        self._scrollState = StateObject(
            wrappedValue: VirtualScrollState(
                conversationId: conversation.id.uuidString,
                initialWindowPosition: .end,
                viewContext: chatDependencies.storage.viewContext,
                makeBackgroundContext: chatDependencies.storage.makeBackgroundContext
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(scrollState.visibleMessages.enumerated()), id: \.element.objectID) { index, message in
                        let absoluteIndex = scrollState.absoluteIndex(forVisibleIndex: index) ?? index
                        Group {
                            if scrollState.placeholderIndices.contains(absoluteIndex) {
                                MessageSkeletonView()
                            } else {
                                MessageBubble(
                                    message: message,
                                    messageBubbleLoader: chatDependencies.content.makeMessageBubbleLoader(),
                                    htmlContentHandler: chatDependencies.content.htmlContentHandler,
                                    isEffectivelyOneToOneConversation: conversation.conversationType == .oneToOne,
                                    style: .compact,
                                    onOpenFullMessage: { messageObjectID, _ in
                                        openFullMessage(messageObjectID: messageObjectID)
                                    }
                                )
                            }
                        }
                        .id(message.objectID) // Use stable objectID instead of volatile index
                        .onAppear {
                            scrollState.markIndexVisible(absoluteIndex)
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
                // Scroll to bottom on appear using stable objectID
                if let lastMessage = scrollState.visibleMessages.last {
                    proxy.scrollTo(lastMessage.objectID, anchor: .bottom)
                }
            }
            .sheet(item: $fullEmailOpenSession) { session in
                FullEmailReaderView(session: session)
            }
        }
    }

    private func openFullMessage(messageObjectID: NSManagedObjectID) {
        guard let message = resolveMessage(with: messageObjectID) else { return }
        fullEmailOpenSession = fullEmailReaderCoordinator.openSession(for: message)
    }

    private func resolveMessage(with objectID: NSManagedObjectID) -> Message? {
        let viewContext = chatDependencies.storage.viewContext
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
