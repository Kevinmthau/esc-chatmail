import XCTest
@testable import esc_chatmail

final class EmailNormalizerTests: XCTestCase {

    // MARK: - normalize Tests

    func testNormalize_gmailWithDots_removesDots() {
        let result = EmailNormalizer.normalize("first.last@gmail.com")
        XCTAssertEqual(result, "firstlast@gmail.com")
    }

    func testNormalize_gmailWithMultipleDots_removesAllDots() {
        let result = EmailNormalizer.normalize("first.middle.last@gmail.com")
        XCTAssertEqual(result, "firstmiddlelast@gmail.com")
    }

    func testNormalize_gmailWithPlusAddressing_removesPlusSuffix() {
        let result = EmailNormalizer.normalize("user+tag@gmail.com")
        XCTAssertEqual(result, "user@gmail.com")
    }

    func testNormalize_gmailWithDotsAndPlus_removesBoth() {
        let result = EmailNormalizer.normalize("first.last+newsletter@gmail.com")
        XCTAssertEqual(result, "firstlast@gmail.com")
    }

    func testNormalize_googlemail_convertsToGmail() {
        let result = EmailNormalizer.normalize("user@googlemail.com")
        XCTAssertEqual(result, "user@gmail.com")
    }

    func testNormalize_googlemailWithDotsAndPlus_normalizesCompletely() {
        let result = EmailNormalizer.normalize("first.last+tag@googlemail.com")
        XCTAssertEqual(result, "firstlast@gmail.com")
    }

    func testNormalize_nonGmailAddress_preservesDots() {
        let result = EmailNormalizer.normalize("first.last@example.com")
        XCTAssertEqual(result, "first.last@example.com")
    }

    func testNormalize_nonGmailAddress_preservesPlusAddressing() {
        let result = EmailNormalizer.normalize("user+tag@outlook.com")
        XCTAssertEqual(result, "user+tag@outlook.com")
    }

    func testNormalize_uppercaseEmail_lowercases() {
        let result = EmailNormalizer.normalize("User@GMAIL.COM")
        XCTAssertEqual(result, "user@gmail.com")
    }

    func testNormalize_whitespace_trimsWhitespace() {
        let result = EmailNormalizer.normalize("  user@gmail.com  ")
        XCTAssertEqual(result, "user@gmail.com")
    }

    func testNormalize_noAtSymbol_returnsLowercasedTrimmed() {
        let result = EmailNormalizer.normalize("  INVALID  ")
        XCTAssertEqual(result, "invalid")
    }

    func testNormalize_emptyString_returnsEmpty() {
        let result = EmailNormalizer.normalize("")
        XCTAssertEqual(result, "")
    }

    // MARK: - isGmailAddress Tests

    func testIsGmailAddress_gmail_returnsTrue() {
        XCTAssertTrue(EmailNormalizer.isGmailAddress("user@gmail.com"))
    }

    func testIsGmailAddress_googlemail_returnsTrue() {
        XCTAssertTrue(EmailNormalizer.isGmailAddress("user@googlemail.com"))
    }

    func testIsGmailAddress_gmailUppercase_returnsTrue() {
        XCTAssertTrue(EmailNormalizer.isGmailAddress("user@GMAIL.COM"))
    }

    func testIsGmailAddress_otherDomain_returnsFalse() {
        XCTAssertFalse(EmailNormalizer.isGmailAddress("user@outlook.com"))
    }

    func testIsGmailAddress_gmailSubdomain_returnsFalse() {
        XCTAssertFalse(EmailNormalizer.isGmailAddress("user@mail.gmail.com"))
    }

    // MARK: - extractEmail Tests

    func testExtractEmail_nameAngleBrackets_extractsEmail() {
        let result = EmailNormalizer.extractEmail(from: "John Smith <john@example.com>")
        XCTAssertEqual(result, "john@example.com")
    }

    func testExtractEmail_quotedNameAngleBrackets_extractsEmail() {
        let result = EmailNormalizer.extractEmail(from: "\"Smith, John\" <john@example.com>")
        XCTAssertEqual(result, "john@example.com")
    }

    func testExtractEmail_plainEmail_returnsEmail() {
        let result = EmailNormalizer.extractEmail(from: "john@example.com")
        XCTAssertEqual(result, "john@example.com")
    }

    func testExtractEmail_bareEmailWithApostrophe_returnsFullEmail() {
        let result = EmailNormalizer.extractEmail(from: "o'connor@example.com")
        XCTAssertEqual(result, "o'connor@example.com")
    }

    func testExtractEmail_bareEmailWithDotAtomSpecials_returnsFullEmail() {
        let result = EmailNormalizer.extractEmail(from: "customer/department=shipping@example.com")
        XCTAssertEqual(result, "customer/department=shipping@example.com")

        let percentResult = EmailNormalizer.extractEmail(from: "user%dept@example.com")
        XCTAssertEqual(percentResult, "user%dept@example.com")
    }

    func testExtractEmail_unsupportedBareLocalPartDoesNotReturnPartialEmail() {
        XCTAssertNil(EmailNormalizer.extractEmail(from: #"o\connor@example.com"#))
        XCTAssertNil(EmailNormalizer.extractEmail(from: "o:connor@example.com"))
    }

    func testExtractEmail_plainEmailWithWhitespace_trimmed() {
        let result = EmailNormalizer.extractEmail(from: "  john@example.com  ")
        XCTAssertEqual(result, "john@example.com")
    }

    func testExtractEmail_commentDisplayName_extractsBareEmail() {
        let result = EmailNormalizer.extractEmail(from: "john@example.com (John Smith)")
        XCTAssertEqual(result, "john@example.com")
    }

    func testExtractEmail_leadingDisplayNameWithoutBrackets_extractsBareEmail() {
        let result = EmailNormalizer.extractEmail(from: "John Smith john@example.com")
        XCTAssertEqual(result, "john@example.com")
    }

    func testExtractEmail_noEmail_returnsNil() {
        let result = EmailNormalizer.extractEmail(from: "John Smith")
        XCTAssertNil(result)
    }

    func testExtractEmail_emptyString_returnsNil() {
        let result = EmailNormalizer.extractEmail(from: "")
        XCTAssertNil(result)
    }

    // MARK: - extractAllEmails Tests

    func testExtractAllEmails_singleEmail_returnsArray() {
        let result = EmailNormalizer.extractAllEmails(from: "john@example.com")
        XCTAssertEqual(result, ["john@example.com"])
    }

    func testExtractAllEmails_multipleEmails_returnsAll() {
        let result = EmailNormalizer.extractAllEmails(from: "john@example.com, jane@example.com")
        XCTAssertEqual(result, ["john@example.com", "jane@example.com"])
    }

    func testExtractAllEmails_mixedFormats_extractsAll() {
        let result = EmailNormalizer.extractAllEmails(from: "John <john@example.com>, jane@example.com")
        XCTAssertEqual(result, ["john@example.com", "jane@example.com"])
    }

    func testExtractAllEmails_commentDisplayName_extractsBareEmail() {
        let result = EmailNormalizer.extractAllEmails(from: "john@example.com (John Smith)")
        XCTAssertEqual(result, ["john@example.com"])
    }

    func testExtractAllEmails_emptyString_returnsEmpty() {
        let result = EmailNormalizer.extractAllEmails(from: "")
        XCTAssertEqual(result, [])
    }

    func testExtractAllEmails_noEmails_returnsEmpty() {
        let result = EmailNormalizer.extractAllEmails(from: "John, Jane")
        XCTAssertEqual(result, [])
    }

    // MARK: - extractDisplayName Tests

    func testExtractDisplayName_nameAngleBrackets_extractsName() {
        let result = EmailNormalizer.extractDisplayName(from: "John Smith <john@example.com>")
        XCTAssertEqual(result, "John Smith")
    }

    func testExtractDisplayName_quotedName_extractsWithoutQuotes() {
        let result = EmailNormalizer.extractDisplayName(from: "\"Smith, John\" <john@example.com>")
        XCTAssertEqual(result, "Smith, John")
    }

    func testExtractDisplayName_plainEmail_returnsNil() {
        let result = EmailNormalizer.extractDisplayName(from: "john@example.com")
        XCTAssertNil(result)
    }

    func testExtractDisplayName_emptyNameBeforeBracket_returnsNil() {
        let result = EmailNormalizer.extractDisplayName(from: "<john@example.com>")
        XCTAssertNil(result)
    }

    func testExtractDisplayName_commentDisplayName_extractsComment() {
        let result = EmailNormalizer.extractDisplayName(from: "john@example.com (John Smith)")
        XCTAssertEqual(result, "John Smith")
    }

    func testExtractDisplayName_leadingDisplayNameWithoutBrackets_extractsName() {
        let result = EmailNormalizer.extractDisplayName(from: "John Smith john@example.com")
        XCTAssertEqual(result, "John Smith")
    }

    // MARK: - extractDisplayName RFC 2047 Tests (issue #149)

    func testExtractDisplayName_rfc2047Base64Name_decodes() {
        let result = EmailNormalizer.extractDisplayName(
            from: "=?utf-8?B?SsO2cmcgTcO8bGxlcg==?= <jorg@example.com>"
        )
        XCTAssertEqual(result, "Jörg Müller")
    }

    func testExtractDisplayName_rfc2047QEncodedName_decodes() {
        let result = EmailNormalizer.extractDisplayName(
            from: "=?utf-8?q?Jos=C3=A9_Garc=C3=ADa?= <jose@example.com>"
        )
        XCTAssertEqual(result, "José García")
    }

    func testExtractDisplayName_quotedRFC2047Name_decodesAndUnquotes() {
        let result = EmailNormalizer.extractDisplayName(
            from: "\"=?utf-8?Q?Costco_Wholesale?=\" <news@costco.example.com>"
        )
        XCTAssertEqual(result, "Costco Wholesale")
    }

    func testExtractDisplayName_rfc2047NameDecodingToQuotedPhrase_stripsDecodedQuotes() {
        // "=?utf-8?B?IkFjbWUsIEluYyI=?=" decodes to "\"Acme, Inc\"" — the
        // quotes only appear after decoding and must still be stripped.
        let result = EmailNormalizer.extractDisplayName(
            from: "=?utf-8?B?IkFjbWUsIEluYyI=?= <hello@acme.example.com>"
        )
        XCTAssertEqual(result, "Acme, Inc")
    }

    func testExtractDisplayName_multiWordRFC2047Name_decodesAcrossWords() {
        // Multibyte character split across adjacent encoded words.
        let result = EmailNormalizer.extractDisplayName(
            from: "=?UTF-8?B?ww==?= =?UTF-8?B?iW1pbGll?= <emilie@example.com>"
        )
        XCTAssertEqual(result, "Émilie")
    }

    func testExtractDisplayName_malformedRFC2047Name_keptVerbatim() {
        let result = EmailNormalizer.extractDisplayName(
            from: "=?utf-8?B?!!!notbase64!!!?= <x@example.com>"
        )
        XCTAssertEqual(result, "=?utf-8?B?!!!notbase64!!!?=")
    }

    func testExtractDisplayName_rfc2047CommentName_decodes() {
        let result = EmailNormalizer.extractDisplayName(
            from: "jose@example.com (=?utf-8?B?Sm9zw6k=?=)"
        )
        XCTAssertEqual(result, "José")
    }

    // MARK: - formatAsDisplayName Tests

    func testFormatAsDisplayName_dotSeparated_formatsAsTitleCase() {
        let result = EmailNormalizer.formatAsDisplayName(email: "firstname.lastname@gmail.com")
        XCTAssertEqual(result, "Firstname Lastname")
    }

    func testFormatAsDisplayName_underscoreSeparated_formatsAsTitleCase() {
        let result = EmailNormalizer.formatAsDisplayName(email: "john_doe@example.com")
        XCTAssertEqual(result, "John Doe")
    }

    func testFormatAsDisplayName_hyphenSeparated_formatsAsTitleCase() {
        let result = EmailNormalizer.formatAsDisplayName(email: "mary-jane@example.com")
        XCTAssertEqual(result, "Mary Jane")
    }

    func testFormatAsDisplayName_singleWord_capitalized() {
        let result = EmailNormalizer.formatAsDisplayName(email: "admin@example.com")
        XCTAssertEqual(result, "Admin")
    }

    func testFormatAsDisplayName_mixedCase_normalizes() {
        let result = EmailNormalizer.formatAsDisplayName(email: "JOHN.DOE@example.com")
        XCTAssertEqual(result, "John Doe")
    }

    func testFormatAsDisplayName_noAtSymbol_formatsUsername() {
        let result = EmailNormalizer.formatAsDisplayName(email: "john.doe")
        XCTAssertEqual(result, "John Doe")
    }

    // MARK: - isBetterDisplayName Tests

    func testIsBetterDisplayName_moreNameParts_isTrue() {
        let result = EmailNormalizer.isBetterDisplayName("John Smith", than: "John")
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_fewerNameParts_isFalse() {
        let result = EmailNormalizer.isBetterDisplayName("John", than: "John Smith")
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_samePartsButLonger_isTrue() {
        let result = EmailNormalizer.isBetterDisplayName("Jonathan Smith", than: "John Smith")
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_samePartsButShorter_isFalse() {
        let result = EmailNormalizer.isBetterDisplayName("John Smith", than: "Jonathan Smith")
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_sameLengthSameParts_isFalse() {
        let result = EmailNormalizer.isBetterDisplayName("John Doe", than: "Jane Doe")
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_newIsNil_isFalse() {
        let result = EmailNormalizer.isBetterDisplayName(nil, than: "John")
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_newIsEmpty_isFalse() {
        let result = EmailNormalizer.isBetterDisplayName("", than: "John")
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_existingIsNil_isTrue() {
        let result = EmailNormalizer.isBetterDisplayName("John", than: nil)
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_existingIsEmpty_isTrue() {
        let result = EmailNormalizer.isBetterDisplayName("John", than: "")
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_bothNil_isFalse() {
        let result = EmailNormalizer.isBetterDisplayName(nil, than: nil)
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_forEmail_replacesSinglePartAddressDerivedName() {
        let result = EmailNormalizer.isBetterDisplayName("Kevin", than: "Kmthau", forEmail: "kmthau@example.com")
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_forEmail_preservesMoreCompleteAddressDerivedName() {
        let result = EmailNormalizer.isBetterDisplayName("John", than: "John Doe", forEmail: "john.doe@example.com")
        XCTAssertFalse(result)
    }

    func testIsBetterDisplayName_forEmail_prefersIntentionalHeaderCasing() {
        let result = EmailNormalizer.isBetterDisplayName("BONBONWHIMS", than: "Bonbonwhims", forEmail: "bonbonwhims@example.com")
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_forEmail_decodedNameReplacesPersistedEncodedWordGarbage() {
        // A garbled raw encoded-word persisted by an earlier build must lose
        // to any decoded candidate — even a "shorter" single-part one.
        let result = EmailNormalizer.isBetterDisplayName(
            "José",
            than: "=?utf-8?B?Sm9zw6k=?=",
            forEmail: "jose@example.com"
        )
        XCTAssertTrue(result)
    }

    func testIsBetterDisplayName_forEmail_encodedWordNeverReplacesCleanName() {
        let result = EmailNormalizer.isBetterDisplayName(
            "=?utf-8?B?Sm9zw6k=?=",
            than: "José",
            forEmail: "jose@example.com"
        )
        XCTAssertFalse(result)
    }

    // MARK: - Hide My Email Detection

    // MARK: - mergeNewestFirstHeaderDisplayName

    func testMergeNewestFirstHeaderDisplayName_rebrandKeepsNewestName() {
        let result = EmailNormalizer.mergeNewestFirstHeaderDisplayName(
            "Technology Brothers",
            into: "TBPN",
            forEmail: "tbpn@mail.beehiiv.com"
        )
        XCTAssertEqual(result, "TBPN")
    }

    func testMergeNewestFirstHeaderDisplayName_olderFullerVariantUpgradesNewestName() {
        let result = EmailNormalizer.mergeNewestFirstHeaderDisplayName(
            "Katie Thau",
            into: "Katie",
            forEmail: "katie@example.com"
        )
        XCTAssertEqual(result, "Katie Thau")
    }

    func testMergeNewestFirstHeaderDisplayName_noWinnerYetUsesCandidate() {
        let result = EmailNormalizer.mergeNewestFirstHeaderDisplayName(
            "Technology Brothers",
            into: nil,
            forEmail: "tbpn@mail.beehiiv.com"
        )
        XCTAssertEqual(result, "Technology Brothers")
    }

    func testMergeNewestFirstHeaderDisplayName_unrelatedOlderNameNeverReplacesNewest() {
        let result = EmailNormalizer.mergeNewestFirstHeaderDisplayName(
            "Completely Different Sender",
            into: "Current Name",
            forEmail: "sender@example.com"
        )
        XCTAssertEqual(result, "Current Name")
    }

    func testIsDisplayNameTokenSubset_subsetAndNonSubset() {
        XCTAssertTrue(EmailNormalizer.isDisplayNameTokenSubset("Katie", of: "Katie Thau"))
        XCTAssertTrue(EmailNormalizer.isDisplayNameTokenSubset("katie thau", of: "Katie Thau"))
        XCTAssertFalse(EmailNormalizer.isDisplayNameTokenSubset("TBPN", of: "Technology Brothers"))
        XCTAssertFalse(EmailNormalizer.isDisplayNameTokenSubset("", of: "Katie Thau"))
    }

    func testIsHideMyEmailDisplayName_exactMatch_returnsTrue() {
        XCTAssertTrue(EmailNormalizer.isHideMyEmailDisplayName("Hide My Email"))
    }

    func testIsHideMyEmailDisplayName_caseAndWhitespaceVariants_returnsTrue() {
        XCTAssertTrue(EmailNormalizer.isHideMyEmailDisplayName("  hide   my   email  "))
        XCTAssertTrue(EmailNormalizer.isHideMyEmailDisplayName("Hide-My-Email"))
    }

    func testIsHideMyEmailDisplayName_otherNames_returnFalse() {
        XCTAssertFalse(EmailNormalizer.isHideMyEmailDisplayName(nil))
        XCTAssertFalse(EmailNormalizer.isHideMyEmailDisplayName(""))
        XCTAssertFalse(EmailNormalizer.isHideMyEmailDisplayName("San Francisco Ballet"))
    }
}
