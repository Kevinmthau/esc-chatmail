import XCTest
@testable import esc_chatmail

/// `PlainTextQuoteRemover` skips a quote pattern whose required literal is
/// not in the text. The shortcut must change no answer: compared with every
/// pattern run, over the golden corpus's texts and attribution lines in every
/// language the patterns cover, in several cases and spellings.
///
/// HONEST SCOPE: this pins that the shortcut changes no answer, not that it
/// saves time; removing `requiredLiteralByPattern` makes nothing here fail.
final class PlainTextQuoteRemoverRequiredLiteralTests: XCTestCase {

    private static let attributionSamples = [
        "On Mon, Jan 1, 2026 at 9:00 AM, Jane Doe <jane@example.com> wrote:",
        "on monday jane WROTE:",
        "> On Jan 1, 2026, at 9:00, Jane wrote:",
        "On Jan 30, 2026 at 7:32 PM, Jane",
        "Am 1. Januar 2026 schrieb Jane Doe <jane@example.com>:",
        "AM 1. JANUAR SCHRIEB JANE:",
        "Le 1 janv. 2026, Jane Doe a écrit :",
        "LE 1 JANV. JANE A ÉCRIT:",
        "Le 1 janv. Jane a e\u{301}crit :",
        "El 1 ene 2026, Jane escribió:",
        "Il giorno 1 gen 2026, Jane ha scritto:",
        "Em 1 de jan. de 2026, Jane escreveu:",
        "Op 1 jan. 2026 schreef Jane Doe <jane@example.com>:",
        "From: Jane\nSent: Monday\nTo: Bob\nSubject: Hi",
        "From: Jane\nSent: Monday\nTo: Bob\nCc: Ann\nSubject: Hi",
        "from: jane\ndate: monday\nto: bob\nsubject: hi",
        "Von: Jane\nGesendet: Montag\nAn: Bob\nBetreff: Hallo",
        "De: Jane\nEnviado: lunes\nPara: Bob\nAsunto: Hola",
        "De : Jane\nEnvoyé : lundi\nÀ : Bob\nObjet : Salut",
        "-----Original Message-----",
        "---------- Forwarded message ---------",
        "Begin forwarded message:",
        "the table people use is simple; el nivel; il until; them system; stop shop",
    ]

    func testEarliestPatternMatch_withAndWithoutTheLiteralShortcut_agree() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "golden_message_corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(QuoteCorpus.self, from: Data(contentsOf: url))
        var texts = corpus.plainTextQuoteCleanupCases.map(\.input)
        texts += corpus.htmlToBubbleTextCases.map { TextProcessing.extractPlainText(from: $0.inputHTML) }
        for sample in Self.attributionSamples {
            texts.append(sample)
            texts.append("Thanks for the update.\n\n" + sample + "\n> quoted line")
            texts.append("prefix text " + sample.lowercased() + " suffix")
            texts.append(sample.uppercased())
        }

        for text in texts {
            let shortcut = PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution(in: text)
            let full = PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution(
                in: text,
                skipsPatternsMissingTheirLiteral: false
            )
            XCTAssertEqual(shortcut.0, full.0, String(text.prefix(80)))
            XCTAssertEqual(shortcut.1, full.1, String(text.prefix(80)))
        }
    }

    /// Each literal must appear in its pattern as written, or the shortcut
    /// could skip a pattern that matches.
    func testRequiredLiterals_appearInTheirPatterns() throws {
        let source = try repositorySource("esc-chatmail/Services/TextProcessing/PlainTextQuoteRemover.swift")
        let entry = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)": "((?:[^"\\]|\\.)*)",$"#, options: [.anchorsMatchLines])
        let matches = entry.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertGreaterThanOrEqual(matches.count, 15)
        for match in matches {
            let pattern = try XCTUnwrap(Range(match.range(at: 1), in: source).map { String(source[$0]) })
            let literal = try XCTUnwrap(Range(match.range(at: 2), in: source).map { String(source[$0]) })
            XCTAssertTrue(pattern.contains(literal), "\(literal) is not in \(pattern)")
            XCTAssertTrue(source.contains("\"\(pattern)\","), "\(pattern) is not a quote pattern")
        }
    }
}

private struct QuoteCorpus: Decodable {
    struct PlainCase: Decodable { let input: String }
    struct HTMLCase: Decodable { let inputHTML: String }

    let plainTextQuoteCleanupCases: [PlainCase]
    let htmlToBubbleTextCases: [HTMLCase]
}
