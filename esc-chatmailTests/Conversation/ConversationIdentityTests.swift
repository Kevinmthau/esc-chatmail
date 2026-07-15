import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationIdentityTests: XCTestCase {

    func testMakeConversationIdentity_excludesHideMyEmailRelayParticipant() {
        let headers = [
            MessageHeader(name: "From", value: "San Francisco Ballet <tickets@sfballet.org>"),
            MessageHeader(name: "To", value: "Hide My Email <thud-others-1n@icloud.com>")
        ]

        let identity = makeConversationIdentity(
            from: headers,
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
            myAliases: ["kthau@me.com", "kmthau@gmail.com"]
        )

        XCTAssertEqual(identity.participants, ["friend@example.com"])
        XCTAssertEqual(identity.type, .oneToOne)
    }

    /// Drift guard between the two participant-set derivations: the header path
    /// (`makeConversationIdentity`, used by the sync router) and the persisted
    /// path (`Message.strictParticipantSetIdentity`, used by the split
    /// migration) must produce identical participant hashes for the same mail,
    /// or migrated and freshly-synced messages fork into duplicate chats.
    func testStrictParticipantSetIdentity_hashMatchesHeaderDerivedIdentity() throws {
        struct Fixture {
            let name: String
            let from: String
            let to: [String]
            let cc: [String]
            let bcc: [String]
            let aliases: Set<String>

            init(
                name: String,
                from: String,
                to: [String],
                cc: [String] = [],
                bcc: [String] = [],
                aliases: Set<String> = ["me@example.com"]
            ) {
                self.name = name
                self.from = from
                self.to = to
                self.cc = cc
                self.bcc = bcc
                self.aliases = aliases
            }
        }

        let fixtures: [Fixture] = [
            Fixture(
                name: "gmail dots and plus collapse into the canonical address",
                from: "K Evin <k.evin+x@gmail.com>",
                to: ["Kevin <kevin@gmail.com>", "me@example.com"]
            ),
            Fixture(
                name: "googlemail.com maps to gmail.com",
                from: "friend@googlemail.com",
                to: ["me@example.com"]
            ),
            Fixture(
                name: "mixed case normalizes to lowercase",
                from: "Alice <ALICE@Example.COM>",
                to: ["Me <ME@example.com>"]
            ),
            Fixture(
                name: "cc participants join the set",
                from: "alice@example.com",
                to: ["me@example.com"],
                cc: ["Bob <bob@example.com>"]
            ),
            Fixture(
                name: "bcc recipients are excluded from identity",
                from: "alice@example.com",
                to: ["me@example.com"],
                bcc: ["Eve <eve@example.com>"]
            ),
            Fixture(
                name: "self-only mail falls back to the sorted-first alias",
                from: "Me <me@example.com>",
                to: ["Kevin <kthau@me.com>"],
                aliases: ["me@example.com", "kthau@me.com"]
            ),
            Fixture(
                name: "hide-my-email From is dropped by both derivations",
                from: "Hide My Email <relay123@privaterelay.appleid.com>",
                to: ["me@example.com"]
            )
        ]

        let stack = TestCoreDataStack()
        let context = stack.viewContext

        for (index, fixture) in fixtures.enumerated() {
            var headers = [MessageHeader(name: "From", value: fixture.from)]
            if !fixture.to.isEmpty {
                headers.append(MessageHeader(name: "To", value: fixture.to.joined(separator: ", ")))
            }
            if !fixture.cc.isEmpty {
                headers.append(MessageHeader(name: "Cc", value: fixture.cc.joined(separator: ", ")))
            }
            // The header path never reads Bcc; the row path must exclude it too.
            if !fixture.bcc.isEmpty {
                headers.append(MessageHeader(name: "Bcc", value: fixture.bcc.joined(separator: ", ")))
            }

            let headerIdentity = makeConversationIdentity(
                from: headers,
                myAliases: fixture.aliases
            )

            let message = MessageBuilder()
                .withId("hash-parity-\(index)")
                .withDate(Date(timeIntervalSince1970: TimeInterval(1_000 + index)))
                .withSender(email: EmailNormalizer.extractEmail(from: fixture.from) ?? fixture.from)
                .build(in: context)
            _ = try MessageParticipantFactory.create(from: fixture.from, kind: .from, for: message, in: context)
            for recipient in fixture.to {
                _ = try MessageParticipantFactory.create(from: recipient, kind: .to, for: message, in: context)
            }
            for recipient in fixture.cc {
                _ = try MessageParticipantFactory.create(from: recipient, kind: .cc, for: message, in: context)
            }
            for recipient in fixture.bcc {
                _ = try MessageParticipantFactory.create(from: recipient, kind: .bcc, for: message, in: context)
            }
            try context.save()

            let messageIdentity = message.strictParticipantSetIdentity(myAliases: fixture.aliases)
            XCTAssertEqual(
                messageIdentity?.participants,
                headerIdentity.participants,
                fixture.name
            )
            XCTAssertEqual(
                messageIdentity?.participantHash,
                headerIdentity.participantHash,
                fixture.name
            )
        }
    }
}
