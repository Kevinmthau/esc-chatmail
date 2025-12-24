import XCTest
@testable import esc_chatmail

/// Tests for sync correctness invariants:
/// - Conversation identity uses participant-based grouping (iMessage-style)
/// - All messages with same participants are in one conversation
/// - BCC is consistently excluded from identity
/// - Self-conversations use deterministic alias selection
class SyncCorrectnessTests: XCTestCase {

    // MARK: - Participant-Based Identity Tests (iMessage-style)

    func testSameParticipantsGroupedTogether() {
        // All messages with the same sender should be in one conversation
        let myAliases: Set<String> = ["me@gmail.com"]

        let headers1 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com"),
            MessageHeader(name: "Subject", value: "Hello")
        ]

        let headers2 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com"),
            MessageHeader(name: "Subject", value: "Different subject")
        ]

        // Different threadIds but same participants should create SAME conversation
        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread123", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread456", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "Same participants should produce same keyHash regardless of threadId")
        XCTAssertTrue(identity1.key.hasPrefix("p|"), "Key should be participant-based")
        XCTAssertEqual(identity1.participants, ["alice@example.com"], "Participants should be the other party")
    }

    func testDifferentParticipantsDifferentConversations() {
        // Messages with different senders should be in different conversations
        let myAliases: Set<String> = ["me@gmail.com"]

        let headers1 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]

        let headers2 = [
            MessageHeader(name: "From", value: "bob@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]

        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread2", myAliases: myAliases)

        XCTAssertNotEqual(identity1.keyHash, identity2.keyHash, "Different participants should produce different keyHashes")
    }

    func testGroupConversationParticipants() {
        // Group emails should include all participants in identity
        let myAliases: Set<String> = ["me@gmail.com"]

        let headers1 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com, bob@example.com")
        ]

        let headers2 = [
            MessageHeader(name: "From", value: "bob@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com, alice@example.com")
        ]

        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread2", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "Same group participants should produce same keyHash")
        XCTAssertEqual(identity1.type, .group, "Should be identified as group")
        XCTAssertEqual(Set(identity1.participants), Set(["alice@example.com", "bob@example.com"]), "Should include all non-me participants")
    }

    func testSentAndReceivedMessagesGrouped() {
        // Messages I send and receive from same person should be in same conversation
        let myAliases: Set<String> = ["me@gmail.com"]

        // Received from Alice
        let headersReceived = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]

        // Sent to Alice
        let headersSent = [
            MessageHeader(name: "From", value: "me@gmail.com"),
            MessageHeader(name: "To", value: "alice@example.com")
        ]

        let identity1 = makeConversationIdentity(from: headersReceived, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headersSent, gmThreadId: "thread2", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "Sent and received messages with same participant should be grouped")
    }

    // MARK: - BCC Consistency Tests

    func testBccExcludedFromIdentity() {
        // BCC should be excluded from conversation identity
        let myAliases: Set<String> = ["me@gmail.com"]

        let headers1 = [
            MessageHeader(name: "From", value: "me@gmail.com"),
            MessageHeader(name: "To", value: "alice@example.com"),
            MessageHeader(name: "Bcc", value: "secret@example.com")
        ]

        let headers2 = [
            MessageHeader(name: "From", value: "me@gmail.com"),
            MessageHeader(name: "To", value: "alice@example.com")
        ]

        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread1", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "BCC should not affect keyHash")
        XCTAssertFalse(identity1.participants.contains("secret@example.com"), "BCC should not be in participants")
    }

    // MARK: - Self-Conversation Determinism Tests

    func testSelfConversationDeterminism() {
        // Self-conversation should use deterministic alias selection (sorted order)
        let myAliases: Set<String> = ["me@gmail.com", "alias@gmail.com", "another@gmail.com"]

        let headers = [
            MessageHeader(name: "From", value: "me@gmail.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]

        let identity1 = makeConversationIdentity(from: headers, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers, gmThreadId: "thread2", myAliases: myAliases)
        let identity3 = makeConversationIdentity(from: headers, gmThreadId: "thread3", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "Self-conversation should produce consistent keyHash")
        XCTAssertEqual(identity2.keyHash, identity3.keyHash, "Self-conversation should produce consistent keyHash")

        // Should use alphabetically first alias
        XCTAssertEqual(identity1.participants, ["alias@gmail.com"], "Should use sorted first alias for self-conversation")
    }

    // MARK: - Email Normalization Tests

    func testGmailNormalization() {
        // Gmail addresses should be normalized consistently
        let myAliases: Set<String> = ["me@gmail.com"]

        let headers1 = [
            MessageHeader(name: "From", value: "john.doe@gmail.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]

        let headers2 = [
            MessageHeader(name: "From", value: "johndoe+work@gmail.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]

        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread2", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "Normalized Gmail addresses should produce same keyHash")
        XCTAssertEqual(identity1.participants, ["johndoe@gmail.com"], "Gmail address should be normalized")
        XCTAssertEqual(identity2.participants, ["johndoe@gmail.com"], "Gmail address should be normalized")
    }

    // MARK: - Conversation Type Tests

    func testConversationTypes() {
        let myAliases: Set<String> = ["me@gmail.com"]

        // One-to-one
        let headers1 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com")
        ]
        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread1", myAliases: myAliases)
        XCTAssertEqual(identity1.type, .oneToOne, "Should be oneToOne with single other participant")

        // Group
        let headers2 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com, bob@example.com")
        ]
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread2", myAliases: myAliases)
        XCTAssertEqual(identity2.type, .group, "Should be group with multiple other participants")
    }

    // MARK: - Notification Sender Grouping Tests

    func testNotificationEmailsGrouped() {
        // All emails from no-reply@accounts.google.com should be in one conversation
        let myAliases: Set<String> = ["me@gmail.com"]

        let headers1 = [
            MessageHeader(name: "From", value: "no-reply@accounts.google.com"),
            MessageHeader(name: "To", value: "me@gmail.com"),
            MessageHeader(name: "Subject", value: "Security alert")
        ]

        let headers2 = [
            MessageHeader(name: "From", value: "no-reply@accounts.google.com"),
            MessageHeader(name: "To", value: "me@gmail.com"),
            MessageHeader(name: "Subject", value: "New sign-in")
        ]

        let identity1 = makeConversationIdentity(from: headers1, gmThreadId: "thread1", myAliases: myAliases)
        let identity2 = makeConversationIdentity(from: headers2, gmThreadId: "thread2", myAliases: myAliases)

        XCTAssertEqual(identity1.keyHash, identity2.keyHash, "All emails from same sender should be in one conversation")
        XCTAssertEqual(identity1.participants, ["no-reply@accounts.google.com"])
    }
}
