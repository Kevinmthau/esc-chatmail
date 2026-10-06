import CoreData
import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// Pins the conversation list row to one height whatever its preview and timestamp hold.
/// Rows size to their text since they stopped being a fixed 88pt (they grow with Dynamic Type,
/// as Messages' rows do), so a line the row's text gains or loses changes that row's height
/// alone and leaves the list uneven.
///
/// HONEST SCOPE: these mount `ConversationRowView` on its own, not in the conversation list's
/// `List`, and for a mailing-list conversation, which loads no participants, so nothing async
/// re-renders the row after mount. Participant loading changes only the title text and the
/// avatar, which sits in a fixed 44pt frame, so it cannot change a row's height on its own.
@MainActor
final class ConversationRowLayoutTests: XCTestCase {
    /// iPhone 17 Pro's width. The list gives the row its full width (zero row insets).
    private static let rowWidth: CGFloat = 402

    /// Far wider than the row at any text size, so the title always truncates.
    private static let longDisplayName = "Swift Evolution Pitches, Proposals and Review Announcements"

    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        // `ConversationSnapshot(from:)` reads the conversation on this @MainActor test body,
        // so the context must be main-queue (`stack.viewContext` is private-queue).
        viewContext = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    func testRowHeight_onePreviewLine_matchesTwoPreviewLines() throws {
        let oneLine = try rowHeight()
        let twoLines = try rowHeight(
            snippet: String(repeating: "Sounds good, see you at the review on Thursday. ", count: 4)
        )

        // Revert-check: dropping `reservesSpace: true` from the preview `Text` in
        // `ConversationRowView.body` makes this fail (68pt to the two-line row's 88pt).
        XCTAssertEqual(oneLine, twoLines, accuracy: 0.01)
    }

    func testRowHeight_emptySnippet_matchesOnePreviewLine() throws {
        let oneLine = try rowHeight()
        let empty = try rowHeight(snippet: "")

        // Revert-check: passing the stored snippet straight through again
        // (`snapshot.snippet ?? "No messages"`) instead of
        // `ConversationRowPolicy.previewText(snippet:)` makes this fail: the empty `Text`
        // does not reserve its two preview lines (64pt to 88pt).
        XCTAssertEqual(empty, oneLine, accuracy: 0.01)
    }

    func testRowHeight_timestampBesideLongTitleAtAccessibilitySize_matchesRowWithoutTimestamp() throws {
        // `TimestampFormatter` shows "Yesterday" for this date in every locale.
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let withoutTimestamp = try rowHeight(
            displayName: Self.longDisplayName,
            lastMessageDate: nil,
            dynamicTypeSize: .accessibility3
        )
        let withTimestamp = try rowHeight(
            displayName: Self.longDisplayName,
            lastMessageDate: yesterday,
            dynamicTypeSize: .accessibility3
        )

        // Revert-check: removing both `.layoutPriority(1)` from the timestamp and chevron
        // stack in `ConversationRowView.body` and the timestamp's `.lineLimit(1)` makes this
        // fail: beside the long title the timestamp gets less than its width and wraps to a
        // second line (201.67pt to 163.67pt).
        // HONEST SCOPE: removing only one of the two passes. Either keeps the timestamp to
        // one line, and a height cannot tell a truncated timestamp (the line limit alone)
        // from a whole one.
        XCTAssertEqual(withTimestamp, withoutTimestamp, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func rowHeight(
        displayName: String = "Swift Evolution",
        snippet: String = "See you then",
        lastMessageDate: Date? = nil,
        dynamicTypeSize: DynamicTypeSize = .large
    ) throws -> CGFloat {
        let builder = ConversationBuilder()
            .asList()
            .withListId("swift-evolution.swift.org")
            .withDisplayName(displayName)
            .withSnippet(snippet)
        if let lastMessageDate {
            _ = builder.withLastMessageDate(lastMessageDate)
        }
        let conversation = builder.build(in: viewContext)

        let row = ConversationRowView(
            snapshot: ConversationSnapshot(from: conversation),
            conversationObjectID: conversation.objectID,
            conversationContext: viewContext,
            currentUserEmail: "me@example.com",
            // Never called: a list row loads no participants.
            participantLoader: ParticipantLoader()
        )
        .environment(\.dynamicTypeSize, dynamicTypeSize)

        let host = try mount(AnyView(row))
        return host.sizeThatFits(
            in: CGSize(width: Self.rowWidth, height: .greatestFiniteMagnitude)
        ).height
    }

    private func mount(_ rootView: AnyView) throws -> UIHostingController<AnyView> {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host app has no window scene to mount the row in"
        )
        let host = UIHostingController(rootView: rootView)
        // The window's safe area is not part of the row.
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        addTeardownBlock { @MainActor in
            window.isHidden = true
        }
        host.view.layoutIfNeeded()
        return host
    }
}
