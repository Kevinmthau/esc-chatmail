import XCTest
import CoreData
@testable import esc_chatmail

/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`,
/// which is private-queue. The test bodies use it directly, so `@MainActor` on
/// the class is what puts those accesses on-queue; see that helper for what the
/// private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
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

    /// The corpus again, through the path sync takes: `MessageProcessor`
    /// parses the headers, and the router builds the identity from what it
    /// parsed (`ConversationManager.createConversationIdentity`). The replay
    /// above feeds raw headers to `makeConversationIdentity(from:)`, which sync
    /// never called, so a rebuild of the parsed To/Cc in between (which added
    /// phantom participants and dropped nameless internationalized ones) went
    /// unseen; web replays the corpus through its production path too.
    ///
    /// Revert-check: rebuilding To/Cc as `name <email>` in
    /// `ConversationManager.createConversationIdentity` again fails
    /// `recipient_name_with_address_and_comma_adds_no_participant`,
    /// `encoded_recipient_name_cannot_replace_address` and
    /// `nameless_internationalized_recipient_is_a_participant`.
    func testCreateConversationIdentity_goldenCorpusThroughTheSyncPath_pinsSharedHashes() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "golden_message_corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(ConversationIdentityCorpus.self, from: Data(contentsOf: url))
        let manager = ConversationManager(contactLinks: { .none })
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in Data() })

        for scenario in corpus.conversationIdentityCases {
            let message = GmailMessage(
                id: "corpus-\(scenario.id)",
                threadId: "thread-\(scenario.id)",
                labelIds: ["INBOX"],
                snippet: "Body",
                historyId: "1",
                internalDate: "1700000000000",
                payload: MessagePart(
                    partId: "",
                    mimeType: "text/plain",
                    filename: nil,
                    headers: scenario.headers,
                    body: MessageBody(size: 4, data: Data("Body".utf8).base64EncodedString(), attachmentId: nil),
                    parts: nil
                ),
                sizeEstimate: nil
            )
            let processed = try await processor.processGmailMessage(message, myAliases: Set(scenario.myAliases))
            let headers = try XCTUnwrap(processed?.headers, scenario.id)

            let identity = manager.createConversationIdentity(from: headers, myAliases: Set(scenario.myAliases))

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

    /// From is folded before Cc, so a Cc entry that repeats the sender's address
    /// as its display name is the later candidate. The fold seeds the Person
    /// name of every participant a new conversation creates.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test.
    func testMakeConversationIdentity_addressShapedCcNameDoesNotReplaceFromName() {
        let headers = [
            MessageHeader(name: "From", value: "Jacob Laycock <jacob.laycock@studs.com>"),
            MessageHeader(name: "To", value: "Kevin <kmthau@gmail.com>"),
            MessageHeader(name: "Cc", value: "\"jacob.laycock@studs.com\" <jacob.laycock@studs.com>")
        ]

        let identity = makeConversationIdentity(
            from: headers,
            myAliases: ["kmthau@gmail.com"]
        )

        XCTAssertEqual(identity.participants, ["jacob.laycock@studs.com"])
        XCTAssertEqual(identity.participantDisplayNames["jacob.laycock@studs.com"], "Jacob Laycock")
    }

    /// A Cc name matching the sender's address ("Jacob Laycock" for
    /// jacob.laycock@) is the later candidate, and it ties the From name on
    /// part count, which the real name wins.
    ///
    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch of `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails
    /// this test (the longer Cc name replaced the From name).
    func testMakeConversationIdentity_addressDerivedCcNameDoesNotReplaceFromName() {
        let headers = [
            MessageHeader(name: "From", value: "Jake Laycock <jacob.laycock@studs.com>"),
            MessageHeader(name: "To", value: "Kevin <kmthau@gmail.com>"),
            MessageHeader(name: "Cc", value: "Jacob Laycock <jacob.laycock@studs.com>")
        ]

        let identity = makeConversationIdentity(
            from: headers,
            myAliases: ["kmthau@gmail.com"]
        )

        XCTAssertEqual(identity.participants, ["jacob.laycock@studs.com"])
        XCTAssertEqual(identity.participantDisplayNames["jacob.laycock@studs.com"], "Jake Laycock")
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
            // Revert-check: Message.strictParticipantSetIdentity must apply
            // the HME exclusion to To and Cc rows as well as From rows.
            Fixture(
                name: "hide-my-email To is dropped by both derivations",
                from: "tickets@sfballet.org",
                to: ["Hide My Email <to-relay@icloud.com>"]
            ),
            Fixture(
                name: "hide-my-email Cc is dropped by both derivations",
                from: "alice@example.com",
                to: ["me@example.com"],
                cc: ["Hide-My-Email <cc-relay@icloud.com>", "Bob <bob@example.com>"]
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
        let context = stack.makeMainQueueViewContext()

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

    // MARK: - Addresses one contact card links

    private static let linkedWork = "morgan@corp.example"
    private static let linkedHome = "m.vale@mail.example"
    private static let oneCard = ContactLinkedAddresses(
        contactAddressLists: [[linkedWork, linkedHome]]
    )

    // Revert-check: `contactLinks.unifiedParticipants` in
    // `makeParticipantSetIdentity`. Hashing the addresses themselves gives the
    // two messages two hashes, which is one person in two chats.
    func testMakeConversationIdentity_twoAddressesOnOneContactCard_shareOneHash() {
        func identity(from sender: String) -> ConversationIdentity {
            makeConversationIdentity(
                from: [
                    MessageHeader(name: "From", value: "Morgan Vale <\(sender)>"),
                    MessageHeader(name: "To", value: "me@example.com")
                ],
                myAliases: ["me@example.com"],
                contactLinks: Self.oneCard
            )
        }

        let fromWork = identity(from: Self.linkedWork)
        let fromHome = identity(from: Self.linkedHome)

        XCTAssertEqual(fromWork.participantHash, fromHome.participantHash)
        XCTAssertEqual(fromWork.type, .oneToOne)
        // The row is the address the message carried: a reply reads the rows,
        // and must not be sent to an address the card merely lists.
        XCTAssertEqual(fromWork.participants, [Self.linkedWork])
        XCTAssertEqual(fromHome.participants, [Self.linkedHome])
        XCTAssertEqual(fromHome.participantDisplayNames[Self.linkedHome], "Morgan Vale")
    }

    func testMakeConversationIdentity_bothAddressesOfOnePersonOnOneMessage_isOneToOne() {
        let identity = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: Self.linkedWork),
                MessageHeader(name: "To", value: "me@example.com"),
                MessageHeader(name: "Cc", value: Self.linkedHome)
            ],
            myAliases: ["me@example.com"],
            contactLinks: Self.oneCard
        )
        let fromWorkAlone = makeParticipantSetIdentity(
            normalizedEmails: [Self.linkedWork],
            myAliases: ["me@example.com"],
            contactLinks: Self.oneCard
        )

        XCTAssertEqual(identity.participantHash, fromWorkAlone.participantHash)
        XCTAssertEqual(identity.type, .oneToOne, "Two addresses of one person are one participant")
        XCTAssertEqual(identity.participants, [Self.linkedHome], "One row for the person")
    }

    func testMakeParticipantSetIdentity_linkedPersonInAGroup_keysTheGroupByThePerson() {
        func group(with address: String) -> ParticipantSetIdentity {
            makeParticipantSetIdentity(
                normalizedEmails: [address, "carol@example.com"],
                myAliases: ["me@example.com"],
                contactLinks: Self.oneCard
            )
        }
        let alone = makeParticipantSetIdentity(
            normalizedEmails: [Self.linkedWork],
            myAliases: ["me@example.com"],
            contactLinks: Self.oneCard
        )

        XCTAssertEqual(group(with: Self.linkedWork).participantHash, group(with: Self.linkedHome).participantHash)
        XCTAssertEqual(group(with: Self.linkedWork).type, .group)
        XCTAssertNotEqual(group(with: Self.linkedWork).participantHash, alone.participantHash)
    }

    /// A link changes the hash of the linked person's conversations and of
    /// nobody else's: with nothing linked, and for anyone no card links, the
    /// hash is the plain address-set hash the web app computes.
    func testMakeParticipantSetIdentity_personNoCardLinks_keepsThePlainAddressHash() {
        for links in [ContactLinkedAddresses.none, Self.oneCard] {
            let identity = makeParticipantSetIdentity(
                normalizedEmails: ["carol@example.com", "me@example.com"],
                myAliases: ["me@example.com"],
                contactLinks: links
            )
            XCTAssertEqual(identity.participantHash, calculateParticipantHash(from: ["carol@example.com"]))
            XCTAssertEqual(identity.participants, ["carol@example.com"])
        }

        let unlinked = makeParticipantSetIdentity(
            normalizedEmails: [Self.linkedWork],
            myAliases: ["me@example.com"],
            contactLinks: .none
        )
        XCTAssertEqual(unlinked.participantHash, calculateParticipantHash(from: [Self.linkedWork]))
    }

    /// The compose path hashes a recipient list and the sync path the echo's
    /// headers. They must agree for a linked address too, or a message sent
    /// to someone's second address opens a chat its echo then leaves.
    func testMakeRecipientParticipantSetIdentity_linkedAddress_matchesTheHeaderDerivedHash() throws {
        let composed = try XCTUnwrap(
            makeRecipientParticipantSetIdentity(
                recipients: [Self.linkedHome],
                myAliases: ["me@example.com"],
                contactLinks: Self.oneCard
            )
        )
        let echoed = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "me@example.com"),
                MessageHeader(name: "To", value: Self.linkedHome)
            ],
            myAliases: ["me@example.com"],
            contactLinks: Self.oneCard
        )
        let received = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: Self.linkedWork),
                MessageHeader(name: "To", value: "me@example.com")
            ],
            myAliases: ["me@example.com"],
            contactLinks: Self.oneCard
        )

        XCTAssertEqual(composed.participantHash, echoed.participantHash)
        XCTAssertEqual(composed.participantHash, received.participantHash)
    }

    /// The drift guard above, with linked addresses: the persisted-row path
    /// must fold them exactly as the header path does.
    ///
    /// Revert-check: the `contactLinks:` argument `strictParticipantSetIdentity`
    /// passes to `makeParticipantSetIdentity`. Left at its default, the row
    /// path hashes with the shared store's map, which holds nothing under
    /// unit tests.
    func testStrictParticipantSetIdentity_linkedAddresses_hashMatchesHeaderDerivedIdentity() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let aliases: Set<String> = ["me@example.com"]

        for (index, sender) in [Self.linkedWork, Self.linkedHome].enumerated() {
            let headerIdentity = makeConversationIdentity(
                from: [
                    MessageHeader(name: "From", value: sender),
                    MessageHeader(name: "To", value: "me@example.com, carol@example.com")
                ],
                myAliases: aliases,
                contactLinks: Self.oneCard
            )

            let message = MessageBuilder()
                .withId("linked-hash-parity-\(index)")
                .withDate(Date(timeIntervalSince1970: TimeInterval(2_000 + index)))
                .withSender(email: sender)
                .build(in: context)
            _ = try MessageParticipantFactory.create(from: sender, kind: .from, for: message, in: context)
            for recipient in ["me@example.com", "carol@example.com"] {
                _ = try MessageParticipantFactory.create(from: recipient, kind: .to, for: message, in: context)
            }
            try context.save()

            let messageIdentity = message.strictParticipantSetIdentity(
                myAliases: aliases,
                contactLinks: Self.oneCard
            )
            XCTAssertEqual(messageIdentity?.participantHash, headerIdentity.participantHash, sender)
            XCTAssertEqual(messageIdentity?.participants, headerIdentity.participants, sender)
            XCTAssertEqual(messageIdentity?.type, .group, sender)
        }

        let fromWork = makeParticipantSetIdentity(
            normalizedEmails: [Self.linkedWork, "carol@example.com"],
            myAliases: aliases,
            contactLinks: Self.oneCard
        )
        let fromHome = makeParticipantSetIdentity(
            normalizedEmails: [Self.linkedHome, "carol@example.com"],
            myAliases: aliases,
            contactLinks: Self.oneCard
        )
        XCTAssertEqual(fromWork.participantHash, fromHome.participantHash)
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
