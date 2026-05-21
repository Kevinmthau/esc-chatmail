import XCTest
@testable import esc_chatmail

final class ConversationIdentityTests: XCTestCase {

    func testMakeConversationIdentity_excludesHideMyEmailRelayParticipant() {
        let headers = [
            MessageHeader(name: "From", value: "San Francisco Ballet <tickets@sfballet.org>"),
            MessageHeader(name: "To", value: "Hide My Email <thud-others-1n@icloud.com>")
        ]

        let identity = makeConversationIdentity(
            from: headers,
            gmThreadId: "thread-1",
            myAliases: ["kmthau@gmail.com"]
        )

        XCTAssertEqual(identity.participants, ["tickets@sfballet.org"])
        XCTAssertEqual(identity.type, .oneToOne)
    }

    func testMakeConversationIdentity_excludesAllSelfAliasesFromRecipients() {
        let headers = [
            MessageHeader(name: "From", value: "Friend <friend@example.com>"),
            MessageHeader(name: "To", value: "Kevin <kthau@me.com>, Kevin Gmail <kmthau@gmail.com>")
        ]

        let identity = makeConversationIdentity(
            from: headers,
            gmThreadId: "thread-2",
            myAliases: ["kthau@me.com", "kmthau@gmail.com"]
        )

        XCTAssertEqual(identity.participants, ["friend@example.com"])
        XCTAssertEqual(identity.type, .oneToOne)
    }
}
