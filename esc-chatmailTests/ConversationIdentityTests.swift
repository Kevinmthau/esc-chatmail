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
}

