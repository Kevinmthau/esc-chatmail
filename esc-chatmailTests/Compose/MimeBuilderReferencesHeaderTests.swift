import XCTest
@testable import esc_chatmail

/// The References header every MIME builder emits: trimmed to the thread's first
/// ID plus the most recent ones, and folded so no physical line passes RFC 5322's
/// limits. A chat-style thread grows the chain by one ID per reply, and this app's
/// own Message-IDs are ~96 characters, so the old single space-joined line passed
/// 998 characters after about ten replies.
final class MimeBuilderReferencesHeaderTests: XCTestCase {

    // MARK: - Trim

    // Revert-check: fails if `MimeBuilder.trimmedReferences` stops capping the chain
    // to the first ID plus the last `referencesRecentIDLimit` — all 40 IDs would be
    // emitted.
    func testReplyBuilders_longReferencesChain_keepFirstAndMostRecentIDsInOrder() throws {
        let chain = (0..<40).map(Self.appMessageID)
        let expected = [chain[0]] + chain.suffix(MimeBuilder.referencesRecentIDLimit)

        for (builder, data) in Self.replyBuilds(references: chain) {
            let header = try Self.referencesHeader(in: data)
            XCTAssertEqual(header.ids, expected, builder)
            XCTAssertEqual(header.ids.last, chain.last, "\(builder): the parent's ID stays last")
        }
    }

    func testTrimmedReferences_atCapBoundary_keepsEveryIDAndDropsOnlyBeyondIt() {
        let limit = MimeBuilder.referencesRecentIDLimit
        let atCap = (0...limit).map(Self.appMessageID)
        XCTAssertEqual(MimeBuilder.trimmedReferences(atCap), atCap)

        let overCap = (0...(limit + 1)).map(Self.appMessageID)
        XCTAssertEqual(
            MimeBuilder.trimmedReferences(overCap),
            [overCap[0]] + overCap.dropFirst(2),
            "Only the oldest non-root ID is dropped one past the cap"
        )
    }

    // MARK: - Fold

    // Revert-check: fails if `MimeBuilder.formatReferencesHeader` joins the trimmed
    // IDs with plain spaces again — even capped, 21 app-sized IDs make one ~2,000
    // character line.
    func testReplyBuilders_longReferencesChain_foldEveryLineWithinRFC5322Limits() throws {
        let chain = (0..<40).map(Self.appMessageID)

        for (builder, data) in Self.replyBuilds(references: chain) {
            let mime = try XCTUnwrap(String(data: data, encoding: .utf8))
            let headerSection = try XCTUnwrap(mime.components(separatedBy: "\r\n\r\n").first)
            for line in headerSection.components(separatedBy: "\r\n") {
                XCTAssertLessThanOrEqual(
                    line.utf8.count,
                    MimeBuilder.headerLineHardLimit,
                    "\(builder): \(line.prefix(40))…"
                )
            }

            let header = try Self.referencesHeader(in: data)
            XCTAssertGreaterThan(header.lines.count, 1, "\(builder): the chain must fold")
            for (index, line) in header.lines.enumerated() {
                if index > 0 {
                    XCTAssertTrue(line.hasPrefix(" "), "\(builder): continuation lines start with SP")
                }
                let idsOnLine = line.split(whereSeparator: \.isWhitespace)
                    .filter { $0 != "References:" }
                XCTAssertTrue(
                    line.utf8.count <= MimeBuilder.headerLineSoftLimit || idsOnLine.count == 1,
                    "\(builder): only a single unfoldable ID may pass 78 characters: \(line)"
                )
            }
        }
    }

    // Revert-check: fails if `MimeBuilder.formatReferencesHeader` stops folding at
    // `headerLineSoftLimit` — six 34-character IDs would share one 220-character line.
    func testReplyBuilders_shortGmailIDs_packSeveralPerLineWithinSoftLimit() throws {
        let chain = (0..<6).map { "<CAB\($0)xyzabcdefghij@mail.gmail.com>" }

        for (builder, data) in Self.replyBuilds(references: chain) {
            let header = try Self.referencesHeader(in: data)
            XCTAssertEqual(header.ids, chain, builder)
            XCTAssertLessThan(header.lines.count, chain.count, "\(builder): short IDs share lines")
            for line in header.lines {
                XCTAssertLessThanOrEqual(line.utf8.count, MimeBuilder.headerLineSoftLimit, builder)
            }
        }
    }

    // MARK: - Unchanged behavior

    func testReplyBuilders_shortReferencesChain_staysOnOneLineWithThreadingHeadersUnchanged() throws {
        let messageID = Self.appMessageID(99)

        for (builder, data) in Self.replyBuilds(
            references: ["<root@example.com>", "<parent@example.com>"],
            inReplyTo: "<parent@example.com>",
            messageId: messageID
        ) {
            let lines = try Self.headerLines(in: data)
            XCTAssertTrue(
                lines.contains("References: <root@example.com> <parent@example.com>"),
                builder
            )
            XCTAssertTrue(lines.contains("In-Reply-To: <parent@example.com>"), builder)
            XCTAssertTrue(lines.contains("Message-ID: \(messageID)"), builder)
        }
    }

    func testReplyBuilders_emptyOrBlankReferences_omitTheHeader() throws {
        for references in [[], [""], ["  ", "\r\n"]] {
            for (builder, data) in Self.replyBuilds(references: references) {
                let lines = try Self.headerLines(in: data)
                XCTAssertFalse(lines.contains { $0.hasPrefix("References:") }, builder)
            }
        }
    }

    // MARK: - Tokenizing

    func testTrimmedReferences_entriesWithEmbeddedWhitespace_areSplitIntoIDs() {
        XCTAssertEqual(
            MimeBuilder.trimmedReferences(["<a@x.com> <b@x.com>", "<c@x.com>\r\n", "", "\t<d@x.com>"]),
            ["<a@x.com>", "<b@x.com>", "<c@x.com>", "<d@x.com>"]
        )
    }

    func testReplyBuilders_crlfInStoredReference_cannotStartANewHeaderLine() throws {
        let chain = ["<root@x.com>", "<a@x.com>\r\nBcc: attacker@example.com"]

        for (builder, data) in Self.replyBuilds(references: chain) {
            let lines = try Self.headerLines(in: data)
            XCTAssertFalse(lines.contains { $0.hasPrefix("Bcc:") }, builder)
        }
    }

    func testTrimmedReferences_idLongerThanAnyHeaderLine_isDropped() {
        let oversized = "<" + String(repeating: "x", count: MimeBuilder.headerLineHardLimit) + "@x.com>"
        XCTAssertEqual(
            MimeBuilder.trimmedReferences(["<root@x.com>", oversized, "<parent@x.com>"]),
            ["<root@x.com>", "<parent@x.com>"]
        )
    }

    // MARK: - Helpers

    /// This app's own Message-ID shape (`<esc-` + 72 hex + `@domain>`), the
    /// longest IDs a chat thread routinely carries.
    private static func appMessageID(_ index: Int) -> String {
        MimeBuilder.messageId(
            forOptimisticMessageID: String(format: "%08d-aaaa-4bbb-8ccc-dddddddddddd", index)
        )
    }

    /// One build per MIME builder that emits threading headers.
    private static func replyBuilds(
        references: [String],
        inReplyTo: String? = "<parent@example.com>",
        messageId: String? = nil
    ) -> [(String, Data)] {
        let attachment = AttachmentData(data: Data("file".utf8), filename: "note.txt", mimeType: "text/plain")
        return [
            (
                "simple",
                MimeBuilder.buildSimpleMessage(
                    to: ["friend@example.com"],
                    from: "me@example.com",
                    fromName: nil,
                    body: "Thanks!",
                    subject: "Re: Lunch",
                    inReplyTo: inReplyTo,
                    references: references,
                    messageId: messageId
                )
            ),
            (
                "multipart",
                MimeBuilder.buildMultipartMessage(
                    to: ["friend@example.com"],
                    from: "me@example.com",
                    fromName: nil,
                    body: "Thanks!",
                    subject: "Re: Lunch",
                    inReplyTo: inReplyTo,
                    references: references,
                    attachments: [attachment],
                    messageId: messageId
                )
            ),
            (
                "alternative (buildReply)",
                MimeBuilder.buildReply(
                    to: ["friend@example.com"],
                    from: "me@example.com",
                    body: "Thanks!",
                    subject: "Re: Lunch",
                    inReplyTo: inReplyTo,
                    references: references,
                    messageId: messageId
                )
            )
        ]
    }

    private static func headerLines(in data: Data) throws -> [String] {
        let mime = try XCTUnwrap(String(data: data, encoding: .utf8))
        let headerSection = try XCTUnwrap(mime.components(separatedBy: "\r\n\r\n").first)
        return headerSection.components(separatedBy: "\r\n")
    }

    /// The References field's physical lines and its unfolded IDs.
    private static func referencesHeader(in data: Data) throws -> (lines: [String], ids: [String]) {
        let lines = try headerLines(in: data)
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("References: ") })
        var fieldLines = [lines[start]]
        for line in lines[(start + 1)...] {
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
            fieldLines.append(line)
        }
        let ids = fieldLines
            .joined()
            .dropFirst("References: ".count)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return (fieldLines, ids)
    }
}
