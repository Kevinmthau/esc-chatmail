import SwiftUI
import CoreData
import Combine

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
                                MessageBubble(
                                    message: message,
                                    conversation: conversation,
                                    style: .compact
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
