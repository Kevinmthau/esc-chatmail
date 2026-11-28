#if os(iOS)
import CoreData
import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// What VoiceOver and Voice Control are given for the iPhone's conversation list, read from the
/// real `ConversationListView` mounted over a test store with the test host's accessibility
/// runtime switched on (`HostedAccessibility`; architecture review 2026-11,
/// gap-accessibility-architecture#1 and #5): each row is one button element whose label is its
/// name, date and preview, whose value is its unread and pinned state, whose Voice Control name
/// is its name, and whose swipe actions are custom actions; while selecting, activating a row
/// toggles its selection and the row says so, and the checkbox is not an element of its own.
///
/// Hygiene: the store is a `TestCoreDataStack`'s and the list's context its container's
/// main-queue one; Contacts are `NobodyContactsResolver`; the auth session has an empty keychain
/// and a throwaway defaults suite. The list's appear still runs `AppPrewarmer.prewarmAll()`,
/// which asks the shared `TokenManager` for a token (none is stored) and makes one empty Contacts
/// fetch, both detached and unawaited.
///
/// HONEST SCOPE: the tree an assistive client is handed, on the iOS 27.0 simulator; nothing is
/// spoken. A row is not activated outside selection mode, which pushes a chat.
@MainActor
final class ConversationListAccessibilityHostedTests: XCTestCase {
    /// Revert-checks, each run: moving the chevron's `.accessibilityHidden(true)` onto
    /// `Text(displayName)` in `ConversationRowView` fails the label; swapping the arguments of its
    /// `ConversationRowAccessibilityPolicy.value(isUnread:isPinned:)` call fails the values;
    /// deleting its `.accessibilityInputLabels` fails the input labels.
    ///
    /// HONEST SCOPE: the row is a button without the list's `.accessibilityAddTraits` (its
    /// default action makes it one), so deleting that call fails only the selection test below;
    /// and deleting the list's own `.accessibilityElement(children: .combine)` changes nothing
    /// read here, since the row combines itself and the checkbox beside it is hidden. That
    /// combine stays, so the row stays one element if either changes.
    func testRows_areOneButtonEach_withNameDatePreviewStateAndSwipeActions() async throws {
        let fixture = try makeFixture()
        try enableHostedAccessibility()
        let host = try mount(fixture)

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            Fixture.names.allSatisfy { name in elements.contains { $0.label.hasPrefix(name) } }
        }

        for (name, value, readAction) in [
            ("Swift Evolution", "", "Unread"),
            ("Unread List", "Unread", "Read"),
            ("Pinned Unread", "Unread, Pinned", "Read")
        ] {
            let rows = elements.filter { $0.label.hasPrefix(name) }
            XCTAssertEqual(rows.count, 1, "One element for the row \(name): \(rows.map(\.description))")
            guard let row = rows.first else { continue }
            XCTAssertTrue(row.label.contains("Preview text for \(name)"), row.description)
            XCTAssertEqual(row.value, value, row.description)
            XCTAssertTrue(row.traits.contains(.button), row.description)
            XCTAssertFalse(row.traits.contains(.selected), row.description)
            XCTAssertEqual(row.inputLabels, [name], row.description)
            XCTAssertEqual(row.customActionNames, [readAction, "Report Spam", "Archive"], row.description)
        }
        // The row's parts have no element of their own.
        XCTAssertFalse(elements.contains { $0.label == "Swift Evolution" || $0.label == "SE" }, "\(elements.map(\.description))")
    }

    /// While selecting, a double-tap on a row selects it, once, and the row says it is selected;
    /// the checkbox is hidden, since the row says the same.
    ///
    /// Revert-checks, each run: `isSelected: false` in place of
    /// `viewModel.selectedConversationIDs.contains(item.id)` in `ConversationListView`, deleting
    /// its `.accessibilityAddTraits` call, deleting the checkbox's `.accessibilityHidden(true)`,
    /// and deleting the row's `.accessibilityAction` each fail the selected trait.
    func testSelecting_activatingARow_selectsItAndOnlyIt() async throws {
        let fixture = try makeFixture()
        try enableHostedAccessibility()
        let host = try mount(fixture)
        let selectTitle = ConversationListChromePolicy.leadingButtonTitle(isSelecting: false)
        let cancelTitle = ConversationListChromePolicy.leadingButtonTitle(isSelecting: true)

        var elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == selectTitle }
                && elements.contains { $0.label.hasPrefix("Unread List") }
        }
        try XCTUnwrap(elements.first { $0.label == selectTitle }).activate()
        elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == cancelTitle }
                && elements.contains { $0.label.hasPrefix("Unread List") && $0.customActionNames.isEmpty }
        }

        XCTAssertTrue(try XCTUnwrap(elements.first { $0.label.hasPrefix("Unread List") }).activate())
        elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label.hasPrefix("Unread List") && $0.traits.contains(.selected) }
        }
        let selected = elements.filter { $0.traits.contains(.selected) }.map(\.label)
        XCTAssertEqual(selected.count, 1, "\(selected)")
        XCTAssertTrue(selected.first?.hasPrefix("Unread List") == true, "\(selected)")

        XCTAssertTrue(try XCTUnwrap(elements.first { $0.label.hasPrefix("Unread List") }).activate())
        elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label.hasPrefix("Unread List") && !$0.traits.contains(.selected) }
        }
        XCTAssertFalse(elements.contains { $0.traits.contains(.selected) }, "One activation, one toggle")
        XCTAssertFalse(
            elements.contains { $0.label == "Circle" || $0.label == "Selected" },
            "The checkbox must not be an element of its own: \(elements.map(\.description))"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        static let names = ["Swift Evolution", "Unread List", "Pinned Unread"]
        let stack: TestCoreDataStack
        let dependencies: Dependencies
    }

    private func makeFixture() throws -> Fixture {
        let stack = TestCoreDataStack()
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationListAccessibilityHostedTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }
        let contactsResolver = NobodyContactsResolver()
        let tokenManager = MockTokenManager()
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ConversationListAccessibilityHostedTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = "me@example.com"
        let dependencies = Dependencies(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            keychainService: MockKeychainService(),
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            contactsResolver: contactsResolver,
            htmlContentHandler: HTMLContentHandler(messagesDirectory: messagesDirectory),
            participantLoader: ParticipantLoader(
                contactsResolver: contactsResolver,
                prefetchDisplayNames: { _ in },
                cachedDisplayNameProvider: { _ in nil },
                photoLoader: { _ in [] }
            )
        )

        let context = dependencies.viewContext
        let now = Date()
        for (index, name) in Fixture.names.enumerated() {
            var builder = ConversationBuilder()
                .withDisplayName(name)
                .withSnippet("Preview text for \(name), long enough to wrap onto a second line of the row.")
                .withLastMessageDate(now.addingTimeInterval(TimeInterval(-3_600 * (index + 1))))
                .visible()
                .hasInboxMessages()
                .asPersonal()
            if name != "Swift Evolution" {
                builder = builder.withUnreadCount(1)
            }
            if name == "Pinned Unread" {
                builder = builder.setPinned()
            }
            _ = builder.build(in: context)
        }
        try context.save()
        return Fixture(stack: stack, dependencies: dependencies)
    }

    private func mount(_ fixture: Fixture) throws -> UIViewController {
        let host = try mountInTestWindow(
            NavigationStack {
                ConversationListView(deps: fixture.dependencies)
            }
        )
        addTeardownBlock { @MainActor in
            host.view.window?.rootViewController = nil
        }
        return host
    }
}
#endif
