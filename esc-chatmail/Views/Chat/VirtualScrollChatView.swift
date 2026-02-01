import SwiftUI
import CoreData
import Combine

// MARK: - Virtual Scroll Chat View
struct VirtualScrollChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var scrollState: VirtualScrollState
    @EnvironmentObject private var deps: Dependencies
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
                    ForEach(Array(scrollState.visibleMessages.enumerated()), id: \.element.objectID) { index, message in
                        Group {
                            if scrollState.placeholderIndices.contains(index) {
                                MessageSkeletonView()
                            } else {
                                MessageBubble(
                                    message: message,
                                    conversation: conversation,
                                    style: .compact
                                )
                            }
                        }
                        .id(message.objectID) // Use stable objectID instead of volatile index
                        .onAppear {
                            scrollState.markIndexVisible(index)
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
        }
    }
}
