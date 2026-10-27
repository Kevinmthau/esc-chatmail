import Foundation

/// Anonymized reproduction of an Outlook reply from a Taiwanese manufacturer whose
/// signature leaked into the chat bubble. Names, numbers and hosts are invented; the
/// row shapes are preserved: a "Tel:" row with no space after the colon, mobile labels
/// qualified by a carrier or region code ("TWM Mobile:", "CQ Mobile:"), an MVPN short
/// number below the seven-digit phone floor, and an "Email:" row last. The upward
/// contact scan used to stop at the MVPN row with a single contact.
///
/// The HTML and the cleaned text are read from the golden corpus case `corpusCaseID`,
/// so the repair and DOM tests pin the same input the corpus replay does; a second
/// copy here could drift from it without failing anything. Only the leaked text, which
/// the corpus does not record, lives here.
enum QualifiedMobileSignatureFixture {
    static let corpusCaseID = "html_outlook_carrier_labeled_mobiles_and_mvpn_signature_removed"

    static func html() throws -> String {
        try corpusCase().inputHTML
    }

    static func expectedChatText() throws -> String {
        try corpusCase().expected
    }

    /// What the bubble showed before the fix: the whole signature below the name.
    static func leakedChatText() throws -> String {
        try expectedChatText() +
            "\n\nExample Computer Inc.\n\nTel:+886-3-555-0123 Ext. 15000\n\nTWM Mobile: 0912555018" +
            "\n\nCQ Mobile: 13800555018\n\nMVPN 655018\n\nEmail: lin.chen@example.test"
    }

    private struct Corpus: Decodable {
        let htmlToBubbleTextCases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let inputHTML: String
        let expected: String
    }

    private final class BundleToken {}

    private static func corpusCase() throws -> Case {
        // The bundled resource, not `#filePath`, as in `GoldenCorpusReplayTests.loadCorpus`:
        // the source path is unreadable from the simulator's test process.
        guard let url = Bundle(for: BundleToken.self).url(forResource: "golden_message_corpus", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        guard let scenario = corpus.htmlToBubbleTextCases.first(where: { $0.id == corpusCaseID }) else {
            throw CocoaError(.coderValueNotFound)
        }
        return scenario
    }
}
