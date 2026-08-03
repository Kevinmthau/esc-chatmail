import XCTest
@testable import esc_chatmail

final class RFC2047DecoderTests: XCTestCase {

    // MARK: - containsEncodedWord

    func testContainsEncodedWord_encodedWord_true() {
        XCTAssertTrue(RFC2047Decoder.containsEncodedWord("=?utf-8?B?Sm9zw6k=?="))
    }

    func testContainsEncodedWord_plainText_false() {
        XCTAssertFalse(RFC2047Decoder.containsEncodedWord("John Smith"))
        XCTAssertFalse(RFC2047Decoder.containsEncodedWord("what?= no opener"))
        XCTAssertFalse(RFC2047Decoder.containsEncodedWord("opener only =?"))
    }

    // MARK: - B encoding

    func testDecode_base64UTF8_decodes() {
        let result = RFC2047Decoder.decode("=?utf-8?B?SsO2cmcgTcO8bGxlcg==?=")
        XCTAssertEqual(result, "Jörg Müller")
    }

    func testDecode_base64MissingPadding_decodes() {
        // Some senders strip the trailing "=" padding ("Sm9zw6k=" → "Sm9zw6k").
        XCTAssertEqual(RFC2047Decoder.decode("=?utf-8?B?Sm9zw6k?="), "José")
    }

    func testDecode_base64Latin1_decodes() {
        let result = RFC2047Decoder.decode("=?iso-8859-1?B?TfxsbGVyIEdtYkg=?=")
        XCTAssertEqual(result, "Müller GmbH")
    }

    func testDecode_base64GB2312_decodes() {
        let result = RFC2047Decoder.decode("=?gb2312?B?vqm2qw==?=")
        XCTAssertEqual(result, "京东")
    }

    // MARK: - Q encoding

    func testDecode_qEncodedUTF8_decodes() {
        let result = RFC2047Decoder.decode("=?utf-8?q?Jos=C3=A9_Garc=C3=ADa?=")
        XCTAssertEqual(result, "José García")
    }

    func testDecode_qEncodedUnderscoreIsSpace() {
        let result = RFC2047Decoder.decode("=?us-ascii?Q?John_Smith?=")
        XCTAssertEqual(result, "John Smith")
    }

    func testDecode_qEncodedLiteralCharactersPassThrough() {
        let result = RFC2047Decoder.decode("=?utf-8?Q?Costco_Wholesale?=")
        XCTAssertEqual(result, "Costco Wholesale")
    }

    // MARK: - Multiple words

    func testDecode_whitespaceBetweenEncodedWords_isDropped() {
        // RFC 2047 §6.2: linear whitespace between adjacent encoded words is
        // deleted; the encoded content carries any intended spacing.
        let result = RFC2047Decoder.decode("=?utf-8?B?QWNtZQ==?= =?utf-8?B?Q29ycA==?=")
        XCTAssertEqual(result, "AcmeCorp")
    }

    func testDecode_multibyteCharacterSplitAcrossWords_decodes() {
        // "Émilie" with the two UTF-8 bytes of "É" split across words: bytes
        // must accumulate across the run before charset decoding.
        let result = RFC2047Decoder.decode("=?UTF-8?B?ww==?= =?UTF-8?B?iW1pbGll?=")
        XCTAssertEqual(result, "Émilie")
    }

    func testDecode_encodedWordMixedWithPlainText_preservesSurroundingText() {
        let result = RFC2047Decoder.decode("Re: =?utf-8?B?Sm9zw6k=?= update")
        XCTAssertEqual(result, "Re: José update")
    }

    func testDecode_charsetWithLanguageTag_decodes() {
        // RFC 2231 language suffix on the charset ("utf-8*en").
        let result = RFC2047Decoder.decode("=?utf-8*en?B?Sm9zw6k=?=")
        XCTAssertEqual(result, "José")
    }

    // MARK: - Malformed input stays verbatim

    func testDecode_plainText_unchanged() {
        XCTAssertEqual(RFC2047Decoder.decode("John Smith"), "John Smith")
    }

    func testDecode_invalidBase64_leftVerbatim() {
        let garbled = "=?utf-8?B?!!!notbase64!!!?="
        XCTAssertEqual(RFC2047Decoder.decode(garbled), garbled)
    }

    func testDecode_invalidQHexEscape_leftVerbatim() {
        let garbled = "=?utf-8?Q?bad=ZZescape?="
        XCTAssertEqual(RFC2047Decoder.decode(garbled), garbled)
    }

    func testDecode_unknownEncodingLetter_leftVerbatim() {
        let garbled = "=?utf-8?X?abcdef?="
        XCTAssertEqual(RFC2047Decoder.decode(garbled), garbled)
    }

    func testDecode_unknownCharset_fallsBackToUTF8() {
        // "Sm9zw6k=" is valid UTF-8 ("José") mislabeled with a bogus charset.
        let result = RFC2047Decoder.decode("=?x-no-such-charset?B?Sm9zw6k=?=")
        XCTAssertEqual(result, "José")
    }

    func testDecode_undecodableWordBetweenValidWords_keepsSpacing() {
        let result = RFC2047Decoder.decode("=?utf-8?B?QWNtZQ==?= =?utf-8?X?bad?= tail")
        XCTAssertEqual(result, "Acme =?utf-8?X?bad?= tail")
    }

    func testDecode_emptyEncodedText_decodesToEmpty() {
        XCTAssertEqual(RFC2047Decoder.decode("=?utf-8?B??="), "")
        XCTAssertEqual(RFC2047Decoder.decode("=?utf-8?Q??="), "")
    }
}
