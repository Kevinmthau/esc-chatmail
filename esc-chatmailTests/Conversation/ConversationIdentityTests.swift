import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationIdentityTests: XCTestCase {

    func testMakeConversationIdentity_goldenCorpusPinsSharedHashes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "golden_message_corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(ConversationIdentityCorpus.self, from: Data(contentsOf: url))
        XCTAssertFalse(corpus.conversationIdentityCases.isEmpty)
        for scenario in corpus.conversationIdentityCases {
            let identity = makeConversationIdentity(from: scenario.headers, myAliases: Set(scenario.myAliases))
            // Revert-check: shared fixed digests detect normalizer, self/BCC/HME
            // filtering, namespace, or Unicode ordering drift on either platform.
            XCTAssertEqual(identity.participants, scenario.expected.participants, scenario.id)
            XCTAssertEqual(identity.participantHash, scenario.expected.participantHash, scenario.id)
            XCTAssertEqual(identity.type.rawValue, scenario.expected.type, scenario.id)
            XCTAssertEqual(identity.listId, scenario.expected.listId, scenario.id)
        }
    }

    func testMakeConversationIdentity_unbalancedAngleBracketInDisplayName_preservesParticipantIdentity() {
        // Revert-check: EmailNormalizer.extractEmail's angle-bracket capture
        // must not include display-name text in the participant address/hash.
        let expected = makeParticipantSetIdentity(
            normalizedEmails: ["tom@x.com"],
            myAliases: ["me@example.com"]
        )

        for headerName in ["From", "To", "Cc"] {
            let identity = makeConversationIdentity(
                from: [
                    MessageHeader(name: headerName, value: "Tom <3 Jerry <tom@x.com>"),
                    MessageHeader(name: "To", value: "me@example.com")
                ],
                myAliases: ["me@example.com"]
            )

            XCTAssertEqual(identity.participants, ["tom@x.com"], headerName)
            XCTAssertEqual(identity.participantHash, expected.participantHash, headerName)
            XCTAssertEqual(identity.type, .oneToOne, headerName)
        }
    }

    func testMakeConversationIdentity_quotedLocalPartWithAngleBracket_preservesParticipantIdentity() {
        let email = #""a<b"@example.com"#
        let expected = makeParticipantSetIdentity(
            normalizedEmails: [email],
            myAliases: ["me@example.com"]
        )

        for headerName in ["From", "To", "Cc"] {
            let identity = makeConversationIdentity(
                from: [
                    MessageHeader(name: headerName, value: "Display <\(email)>"),
                    MessageHeader(name: "To", value: "me@example.com")
                ],
                myAliases: ["me@example.com"]
            )

            XCTAssertEqual(identity.participants, [email], headerName)
            XCTAssertEqual(identity.participantHash, expected.participantHash, headerName)
            XCTAssertEqual(identity.type, .oneToOne, headerName)
        }
    }

    func testMakeConversationIdentity_unbalancedDisplayNameBracket_preservesLaterParticipants() {
        let participants = ["alice@example.com", "tom@x.com"]
        let expected = makeParticipantSetIdentity(
            normalizedEmails: Set(participants),
            myAliases: ["me@example.com"]
        )

        for headerName in ["From", "To", "Cc"] {
            let identity = makeConversationIdentity(
                from: [
                    MessageHeader(name: headerName, value: "Tom <3 Jerry <tom@x.com>, Alice <alice@example.com>"),
                    MessageHeader(name: "To", value: "me@example.com")
                ],
                myAliases: ["me@example.com"]
            )

            XCTAssertEqual(identity.participants, participants, headerName)
            XCTAssertEqual(identity.participantHash, expected.participantHash, headerName)
            XCTAssertEqual(identity.type, .group, headerName)
        }
    }

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

    func testMakeConversationIdentity_listIdGroupsByListNamespace() {
        let headers = [
            MessageHeader(name: "From", value: "Alice <alice@example.com>"),
            MessageHeader(name: "To", value: "me@example.com"),
            MessageHeader(name: "List-Id", value: "Swift Evolution <Swift-Evolution.swift.ORG>")
        ]

        let identity = makeConversationIdentity(from: headers, myAliases: ["me@example.com"])

        XCTAssertEqual(identity.type, .list)
        XCTAssertEqual(identity.listId, "swift-evolution.swift.org")
        XCTAssertEqual(identity.listTitle, "Swift Evolution")
        XCTAssertEqual(
            identity.participantHash,
            calculateListConversationHash(fromNormalizedListId: "swift-evolution.swift.org")
        )
        XCTAssertTrue(identity.key.hasPrefix("l|swift-evolution.swift.org|"))
        XCTAssertEqual(identity.participants, ["alice@example.com"], "rows still seed from the participant set")
    }

    func testMakeConversationIdentity_sameListIdAcrossDifferentSendersSharesHash() {
        let first = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "alice@example.com"),
                MessageHeader(name: "To", value: "me@example.com"),
                MessageHeader(name: "List-Id", value: "<list.example.com>")
            ],
            myAliases: ["me@example.com"]
        )
        let second = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "bob@other.org"),
                MessageHeader(name: "To", value: "everyone@list.example.com"),
                MessageHeader(name: "Cc", value: "carol@example.com"),
                MessageHeader(name: "List-Id", value: "<list.example.com>")
            ],
            myAliases: ["me@example.com"]
        )
        let otherList = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "alice@example.com"),
                MessageHeader(name: "To", value: "me@example.com"),
                MessageHeader(name: "List-Id", value: "<other.example.com>")
            ],
            myAliases: ["me@example.com"]
        )

        XCTAssertEqual(first.participantHash, second.participantHash)
        XCTAssertNotEqual(first.participantHash, otherList.participantHash)
    }

    func testMakeConversationIdentity_malformedListIdFallsBackToParticipantIdentity() {
        let plainHeaders = [
            MessageHeader(name: "From", value: "Alice <alice@example.com>"),
            MessageHeader(name: "To", value: "me@example.com")
        ]
        let malformedListHeaders = plainHeaders + [MessageHeader(name: "List-Id", value: "<>")]

        let plain = makeConversationIdentity(from: plainHeaders, myAliases: ["me@example.com"])
        let malformed = makeConversationIdentity(from: malformedListHeaders, myAliases: ["me@example.com"])

        XCTAssertNil(malformed.listId)
        XCTAssertNil(malformed.listTitle)
        XCTAssertEqual(malformed.participantHash, plain.participantHash)
        XCTAssertEqual(malformed.type, plain.type)
        XCTAssertEqual(malformed.participants, plain.participants)
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
            let listId: String?

            init(
                name: String,
                from: String,
                to: [String],
                cc: [String] = [],
                bcc: [String] = [],
                aliases: Set<String> = ["me@example.com"],
                listId: String? = nil
            ) {
                self.name = name
                self.from = from
                self.to = to
                self.cc = cc
                self.bcc = bcc
                self.aliases = aliases
                self.listId = listId
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
            ),
            Fixture(
                name: "list mail keys by List-Id in both derivations",
                from: "Announcements <announce@lists.example.com>",
                to: ["me@example.com"],
                listId: "Project Announcements <announce.lists.example.com>"
            ),
            Fixture(
                name: "bare List-Id keys identically in both derivations",
                from: "notifications@github.com",
                to: ["me@example.com"],
                cc: ["subscribed@noreply.github.com"],
                listId: "<repo.owner.github.com>"
            ),
            Fixture(
                name: "self-alias From with List-Id still keys by list",
                from: "Me <me@example.com>",
                to: ["announce@lists.example.com"],
                listId: "<announce.lists.example.com>"
            ),
            Fixture(
                name: "hide-my-email From with List-Id keys by list in both derivations",
                from: "Hide My Email <relay123@privaterelay.appleid.com>",
                to: ["me@example.com"],
                listId: "<announce.lists.example.com>"
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
            if let listId = fixture.listId {
                headers.append(MessageHeader(name: "List-Id", value: listId))
            }

            let headerIdentity = makeConversationIdentity(
                from: headers,
                myAliases: fixture.aliases
            )

            let builder = MessageBuilder()
                .withId("hash-parity-\(index)")
                .withDate(Date(timeIntervalSince1970: TimeInterval(1_000 + index)))
                .withSender(email: EmailNormalizer.extractEmail(from: fixture.from) ?? fixture.from)
            if let listId = fixture.listId {
                // Mirror the persister: the row path reads the stored
                // normalized id, never the raw header value.
                _ = builder.withListId(try XCTUnwrap(ParsedListId.parse(listId)).id)
            }
            let message = builder.build(in: context)
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
            XCTAssertEqual(
                messageIdentity?.listId,
                headerIdentity.listId,
                fixture.name
            )
        }
    }
}

private struct ConversationIdentityCorpus: Decodable {
    let conversationIdentityCases: [IdentityCase]

    struct IdentityCase: Decodable {
        let id: String
        let headers: [MessageHeader]
        let myAliases: [String]
        let expected: Expected
    }

    struct Expected: Decodable {
        let participants: [String]
        let participantHash: String
        let type: String
        let listId: String?
    }
}
