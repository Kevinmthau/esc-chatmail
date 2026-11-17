import Foundation

/// Recognizes a legal disclaimer at the end of a message, for both the HTML cleanup
/// (`EmailDOMQuoteRemover.truncateTrailingLegalDisclaimer`) and the plain-text one
/// (`PlainTextSignatureRemover.removeSignature`). Mirrored by `web/src/mime/legalDisclaimer.ts`.
///
/// The sentence markers (`If you are not the intended recipient`, `This email is
/// confidential`) only know a few fixed wordings, so a disclaimer worded any other way
/// stayed in the bubble: a Front transport footer opening "This communication is the
/// property of …" and saying "If you are not an addressee" rather than "the intended
/// recipient" was shown in full under every reply (2026-11-17). No single sentence
/// identifies a disclaimer, so this counts distinct kinds of legal clause and asks for
/// several of them, one of which must say who the message is for. An authored sentence
/// that names one clause ("Please keep this confidential.", "Disclaimer: figures are
/// provisional.") is never enough, and a paragraph that names none ends the disclaimer,
/// so a postscript or an authored line after it keeps the whole tail. And the disclaimer
/// starts at its heading or where it says who the message is for (`opensDisclaimer`): an
/// authored line just above it that names two other clauses ("Please keep this
/// confidential and delete the attachments after review.") was cut with it when the
/// disclaimer could start at any paragraph naming two.
///
/// HONEST SCOPE: a disclaimer hard-wrapped so that a line starts with a capital in the
/// middle of a sentence ("… the property of" / "Northwind and its …") splits into two
/// paragraphs, and the part with no clause stays. Paragraphs with no clause at all
/// ("Email cannot be guaranteed to be secure.") end the disclaimer too, and a
/// disclaimer whose last paragraph is one of them stays whole. A disclaimer whose first
/// paragraph names two clauses but not the reader ("This email is confidential and may
/// be privileged. Unauthorized use is prohibited.") keeps that paragraph: by its clauses
/// it cannot be told from an authored line. And authored paragraphs that themselves say
/// who a message is for, each naming two clauses, are still taken for a disclaimer.
enum LegalDisclaimerPolicy {
    /// One kind of legal clause. A disclaimer names several kinds; repeating one kind
    /// (the Front footer is the same paragraph twice) counts it once.
    enum Clause: CaseIterable {
        /// "If you are not the intended recipient", "received this e-mail in error".
        case misdirectedReader
        /// "confidential", "privileged", "proprietary".
        case confidentiality
        /// "intended solely for the use of the addressee", "for the exclusive use of".
        case intendedReader
        /// "notify the sender", "notify us".
        case notifySender
        /// "delete this message", "destroy all copies".
        case deleteMessage
        /// "disclaim", "prohibited", "unauthorized", "dissemination", "reservation of rights".
        case prohibition
    }

    /// What `LegalDisclaimerPolicy` makes of one paragraph of the tail.
    struct ParagraphEvidence: Equatable {
        let clauses: Set<Clause>
        let isHeading: Bool
        let isEnvironmentFooter: Bool
        let isPostscript: Bool

        /// A paragraph that can be part of a disclaimer: a heading, an environment
        /// footer, or one that names two kinds of clause. One clause is the most an
        /// authored line next to a disclaimer usually names, so it ends the disclaimer.
        var belongsToDisclaimer: Bool {
            !isPostscript && (isHeading || isEnvironmentFooter || clauses.count >= 2)
        }

        /// A paragraph a disclaimer can start at: its heading, an environment footer, or
        /// one that says who the message is for. Two other clauses ("Please keep this
        /// confidential and delete the attachments.") are what an authored line above a
        /// disclaimer names, so a run starting at one starts below it.
        var opensDisclaimer: Bool {
            belongsToDisclaimer && (
                isHeading || isEnvironmentFooter ||
                    clauses.contains(.misdirectedReader) || clauses.contains(.intendedReader)
            )
        }
    }

    /// The index of the first line of a trailing disclaimer in `lines`, or nil when the
    /// tail is not one or nothing would be left above it.
    ///
    /// `lines` are visible lines in order; an empty line ends a paragraph. A line whose
    /// predecessor does not end a sentence and which starts with a lowercase letter
    /// continues its predecessor's paragraph (a hard-wrapped disclaimer). The disclaimer
    /// is the longest run of paragraphs at the end that each `belongsToDisclaimer`, from
    /// the first of them that `opensDisclaimer`, taken whole only when their text
    /// together `isDisclaimer`.
    static func trailingDisclaimerStartLine(in lines: [String]) -> Int? {
        let found = paragraphs(in: lines)
        guard found.count >= 2 else { return nil }

        // Up the run from the end, keeping the highest paragraph it can start at: a
        // two-clause paragraph above that one is authored and stays.
        var index = found.count
        var opening: Int?
        while index > 1 {
            let candidate = evidence(for: found[index - 1].text)
            guard candidate.belongsToDisclaimer else { break }
            index -= 1
            if candidate.opensDisclaimer { opening = index }
        }
        guard let start = opening else { return nil }

        let runText = found[start...].map(\.text).joined(separator: " ")
        guard isDisclaimer(runText) else { return nil }
        return found[start].firstLine
    }

    /// Text that names at least three kinds of clause, one of them a statement of who
    /// the message is for or what a reader it was not meant for must do.
    static func isDisclaimer(_ text: String) -> Bool {
        let found = clauses(in: text)
        guard found.contains(.misdirectedReader) || found.contains(.intendedReader) else { return false }
        return found.count >= 3
    }

    static func evidence(for paragraph: String) -> ParagraphEvidence {
        let text = normalized(paragraph)
        return ParagraphEvidence(
            clauses: clauses(in: text),
            isHeading: matches(headingPattern, text),
            isEnvironmentFooter: matches(environmentFooterPattern, text),
            isPostscript: matches(postscriptPattern, text)
        )
    }

    static func clauses(in text: String) -> Set<Clause> {
        let text = normalized(text)
        return Set(Clause.allCases.filter { clause in
            clausePatterns[clause]?.contains { matches($0, text) } ?? false
        })
    }

    // MARK: - Paragraphs

    private struct Paragraph {
        let firstLine: Int
        var text: String
    }

    private static func paragraphs(in lines: [String]) -> [Paragraph] {
        var result: [Paragraph] = []
        var previousLine: String?
        for (index, rawLine) in lines.enumerated() {
            let line = normalized(rawLine)
            guard !line.isEmpty else {
                previousLine = nil
                continue
            }
            if let previousLine, continuesParagraph(previousLine, with: line), !result.isEmpty {
                result[result.count - 1].text += " " + line
            } else {
                result.append(Paragraph(firstLine: index, text: line))
            }
            previousLine = line
        }
        return result
    }

    private static func continuesParagraph(_ previous: String, with line: String) -> Bool {
        guard let last = previous.last, !".!?:;".contains(last) else { return false }
        return line.first?.isLowercase == true
    }

    // MARK: - Patterns

    /// Explicit word edges, so ICU here and JavaScript's `u` flag on the web agree on
    /// where a word starts (`\b` is Unicode-aware in ICU and ASCII-only in JavaScript).
    private static let wordStart = #"(?<![\p{L}\p{N}_])"#
    private static let wordEnd = #"(?![\p{L}\p{N}_])"#

    private static let clausePatterns: [Clause: [NSRegularExpression]] = {
        let start = wordStart
        let end = wordEnd
        let raw: [Clause: [String]] = [
            .misdirectedReader: [
                start + #"if you (?:are not|aren't|are no longer)(?: (?:the|an?))? (?:intended |named |designated |authori[sz]ed )?(?:recipient|addressee)"#,
                start + #"not (?:the|an?) intended recipient"#,
                start + #"received (?:this|the|that) (?:e-?mail|message|communication|transmission|electronic mail)(?: \S+){0,4}? (?:in error|by mistake|in mistake|erroneously)"#
            ],
            .confidentiality: [
                start + #"(?:confidential(?:ity)?|privileged|proprietary)"# + end
            ],
            .intendedReader: [
                start + #"(?:intended|meant) (?:solely |only |exclusively )?for (?:only |solely |exclusively )?(?:the )?(?:(?:sole|exclusive|personal) )?(?:and confidential )?(?:use of )?(?:the )?(?:individual|person|entity|addressee|recipient|named|intended|designated)"#,
                start + #"for the (?:sole|exclusive)(?: and confidential)? use of"# + end
            ],
            .notifySender: [
                start + #"(?:notify|inform|advise|alert) (?:the sender|sender|us)"# + end
            ],
            .deleteMessage: [
                start + #"(?:delete|destroy|discard|erase|purge)"# + end + #"[^.;!?]{0,40}?"# + start +
                    #"(?:e-?mails?|messages?|communications?|transmissions?|copies|attachments?)"# + end
            ],
            .prohibition: [
                start + #"(?:disclaim(?:s|ed|er)?|prohibited|unauthori[sz]ed|dissemination|reservation of rights)"# + end
            ]
        ]
        return raw.mapValues { patterns in
            patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        }
    }()

    /// A paragraph that is only a disclaimer's title: "CONFIDENTIALITY NOTICE",
    /// "Disclaimer:", "LEGAL DISCLAIMER", "Important notice:".
    private static let headingPattern = try? NSRegularExpression(
        pattern: #"^(?:(?:important|legal|confidentiality|privacy|e-?mail)\s+)?(?:notice|disclaimer|confidential(?:ity)?(?:\s+notice)?)\s*:?$"#,
        options: [.caseInsensitive]
    )

    /// "Please consider the environment before printing this e-mail." The plain-text
    /// signature remover already treats it as a footer.
    private static let environmentFooterPattern = try? NSRegularExpression(
        pattern: #"^(?:please )?(?:consider the environment|think before you print)"# + wordEnd,
        options: [.caseInsensitive]
    )

    /// "P.S. …", "PS: …": a postscript is authored, whatever it says.
    private static let postscriptPattern = try? NSRegularExpression(
        pattern: #"^p\.?\s?s(?:\.|:|\s|$)"#,
        options: [.caseInsensitive]
    )

    private static func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        pattern?.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    /// No-break spaces and runs of whitespace read as one space, and a typographic
    /// apostrophe as a straight one ("aren’t").
    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
