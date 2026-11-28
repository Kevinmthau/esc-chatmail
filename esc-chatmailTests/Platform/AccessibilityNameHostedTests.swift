#if os(iOS)
import CoreData
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The names VoiceOver and Voice Control are given for the shared icon-only controls, read from
/// the mounted components with the test host's accessibility runtime switched on
/// (`HostedAccessibility`; architecture review 2026-11, gap-accessibility-architecture#5).
///
/// HONEST SCOPE: the tree an assistive client is handed, on the iOS 27.0 simulator; nothing is
/// spoken. The chat's "More" menu and the Mac's controls are pinned from source
/// (`AccessibilityNameSourceTests`): mounting `ChatView` needs a whole chat, and the Mac test host
/// has no such switch.
@MainActor
final class AccessibilityNameHostedTests: XCTestCase {
    /// Revert-checks, each run: deleting `.accessibilityLabel("Send")` from `SendButton` fails
    /// the name; deleting its `.accessibilityValue` fails the sending value (empty in this mount;
    /// the review read the spinner's "1" there in New Message); `.help("Send")` in place of its
    /// `.macHelp("Send")` fails the empty hint.
    func testSendButton_isNamedSend_andSaysSendingWhileItsSpinnerIsDrawn() async throws {
        try enableHostedAccessibility()
        let host = try mountInTestWindow(
            VStack(spacing: 20) {
                SendButton(isEnabled: true, isSending: false) {}
                SendButton(isEnabled: false, isSending: true) {}
                SendButton(isEnabled: false, isSending: true, showsProgress: false) {}
            }
            .padding()
        )

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.filter { $0.label == "Send" }.count == 3
        }
        let buttons = elements.filter { $0.label == "Send" }
        guard buttons.count == 3 else {
            return XCTFail("Three Send buttons: \(elements.map(\.description))")
        }

        XCTAssertEqual(buttons.map(\.value), ["", "Sending", ""], buttons.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(buttons.allSatisfy { $0.traits.contains(.button) })
        XCTAssertTrue(buttons.allSatisfy { $0.hint.isEmpty }, "No tooltip as a hint on iOS (`macHelp`)")
        XCTAssertFalse(buttons[0].traits.contains(.notEnabled))
        XCTAssertTrue(buttons[1].traits.contains(.notEnabled))
    }

    /// Why `macHelp` exists: on iOS, `help(_:)` is also the element's hint, so a control named
    /// by its tooltip's words would be read twice.
    ///
    /// HONEST SCOPE: this pins SwiftUI's behavior on this runtime, not app code; the app's own
    /// controls are checked for an empty hint above.
    func testHelpOnIOS_isAlsoTheAccessibilityHint() async throws {
        try enableHostedAccessibility()
        let host = try mountInTestWindow(
            Button("Probe") {}
                .help("Probe tip")
                .padding()
        )

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == "Probe" }
        }

        XCTAssertEqual(elements.first { $0.label == "Probe" }?.hint, "Probe tip")
    }

    /// Revert-check: deleting the label from `DraftAttachmentThumbnail` fails this.
    func testDraftAttachmentRemove_isNamedForItsFile() async throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let attachment = AttachmentBuilder()
            .withId("local_name-test-\(UUID().uuidString)")
            .asImage()
            .withFilename("beach.jpg")
            .build(in: context)
        try enableHostedAccessibility()
        let host = try mountInTestWindow(
            DraftAttachmentThumbnail(attachment: attachment) {}
                .padding()
        )

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == "Remove beach.jpg" }
        }
        let remove = try XCTUnwrap(elements.first { $0.label == "Remove beach.jpg" })

        XCTAssertTrue(remove.traits.contains(.button), remove.description)
        XCTAssertTrue(remove.hint.isEmpty, remove.description)
    }

    /// Revert-check: deleting the label from `RecipientChip` fails this.
    func testRecipientChipRemove_isNamedForItsRecipient() async throws {
        try enableHostedAccessibility()
        let host = try mountInTestWindow(
            RecipientChip(recipient: Recipient(email: "ada@example.com", displayName: "Ada Lovelace")) {}
                .padding()
        )

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == "Remove Ada Lovelace" }
        }

        XCTAssertTrue(try XCTUnwrap(elements.first { $0.label == "Remove Ada Lovelace" }).traits.contains(.button))
    }

    /// The iPhone's quote row is its label and its X, named; the arrow before the label is not an
    /// element.
    ///
    /// Revert-checks, each run: deleting the X's `.accessibilityLabel` in
    /// `ChatReplyBarHeaderRow` fails the X's name; deleting the arrow's `.accessibilityHidden(true)`
    /// fails the element count.
    func testQuoteRow_isItsLabelAndANamedX() async throws {
        try enableHostedAccessibility()
        let host = try mountInTestWindow(
            ChatReplyBarHeaderRow(
                header: .replyingTo(label: "Replying to Ada", unabridgedLabel: nil),
                allowsDraftMutation: true,
                isQuoteRowOpen: .constant(false),
                onDropQuote: {},
                onClearUnavailableTarget: {}
            )
            .frame(width: 390)
        )

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == ReplyIndicatorPolicy.dropQuoteLabel }
        }

        XCTAssertEqual(
            elements.map(\.label),
            ["Replying to Ada", ReplyIndicatorPolicy.dropQuoteLabel],
            elements.map(\.description).joined(separator: "\n")
        )
        XCTAssertTrue(elements.last?.traits.contains(.button) == true)
    }
}
#endif
