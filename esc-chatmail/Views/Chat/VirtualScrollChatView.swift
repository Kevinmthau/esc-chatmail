import SwiftUI
import CoreData
import Combine

// MARK: - Virtual Scroll Chat View
struct VirtualScrollChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var scrollState: VirtualScrollState
    @State private var scrollViewReader: ScrollViewProxy?
    @State private var messageToViewInFull: Message?
    private let chatDependencies: ChatDependencies

    init(conversation: Conversation, chatDependencies: ChatDependencies) {
        self.conversation = conversation
        self.chatDependencies = chatDependencies
        self._scrollState = StateObject(
            wrappedValue: VirtualScrollState(
                conversationId: conversation.id.uuidString,
                initialWindowPosition: .end,
                viewContext: chatDependencies.viewContext,
                makeBackgroundContext: chatDependencies.makeBackgroundContext
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
                                    conversation: conversation,
                                    messageBubbleLoader: chatDependencies.makeMessageBubbleLoader(),
                                    htmlContentHandler: chatDependencies.htmlContentHandler,
                                    style: .compact,
                                    onOpenFullMessage: { selectedMessage in
                                        messageToViewInFull = selectedMessage
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
            .sheet(item: $messageToViewInFull) { message in
                HTMLMessageView(message: message)
            }
        }
    }
}
