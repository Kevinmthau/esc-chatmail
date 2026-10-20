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

    func testExtractEmail_unbalancedAngleBracketInDisplayName_extractsOnlyAddress() {
        // Revert-check: unquoted display-name brackets must not become part of
        // the address capture, or it returns "3 Jerry <tom@x.com".
        let result = EmailNormalizer.extractEmail(from: "Tom <3 Jerry <tom@x.com>")
        XCTAssertEqual(result, "tom@x.com")
    }

    func testExtractEmail_quotedLocalPartWithAngleBrackets_preservesAddress() {
        let emails = [
            #""a<b"@example.com"#,
            #""a>b"@example.com"#,
            #""a<b>c"@example.com"#,
            #""a@<b>"@example.com"#,
            #""a\"<b"@example.com"#,
            #""a\\<b"@example.com"#,
            #""a\<b\>"@example.com"#
        ]

        for email in emails {
            XCTAssertEqual(EmailNormalizer.extractEmail(from: "Display <\(email)>"), email)
            XCTAssertEqual(EmailNormalizer.extractEmail(from: "Tom <3 Jerry <\(email)>"), email)
        }
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

    // MARK: - isBetterDisplayName: address-shaped names

    /// A To/Cc header written as `"jacob.laycock@studs.com" <jacob.laycock@studs.com>`
    /// splits into more comparison parts than the address-derived "Jacob Laycock",
    /// which is how it used to take the stored name.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test.
    func testIsBetterDisplayName_forEmail_addressShapedNameNeverReplacesAddressDerivedName() {
        let result = EmailNormalizer.isBetterDisplayName(
            "jacob.laycock@studs.com",
            than: "Jacob Laycock",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertFalse(result)
    }

    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (the longer address beat a one-word name of the same part count).
    func testIsBetterDisplayName_forEmail_addressShapedNameNeverReplacesOneWordName() {
        let result = EmailNormalizer.isBetterDisplayName(
            "jacob.laycock@studs.com",
            than: "Jake",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertFalse(result)
    }

    /// The other half of the rule, and what heals a row that already holds the
    /// address: the next header that names the person replaces it.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (a one-word name shorter than the address never won it back).
    func testIsBetterDisplayName_forEmail_nameReplacesAddressShapedName() {
        let result = EmailNormalizer.isBetterDisplayName(
            "Jake",
            than: "jacob.laycock@studs.com",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertTrue(result)
    }

    /// The stored name must not depend on which header was processed last.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (From-then-Cc order ended on the address).
    func testIsBetterDisplayName_forEmail_headerOrderDoesNotFlipNameToAddress() {
        let email = "jacob.laycock@studs.com"
        func fold(_ candidates: [String]) -> String? {
            candidates.reduce(nil) { stored, candidate in
                EmailNormalizer.isBetterDisplayName(candidate, than: stored, forEmail: email) ? candidate : stored
            }
        }

        XCTAssertEqual(fold(["Jacob Laycock", email]), "Jacob Laycock", "From header, then an address-shaped Cc name")
        XCTAssertEqual(fold([email, "Jacob Laycock"]), "Jacob Laycock", "Address-shaped To name, then a From header")
    }

    /// HONEST SCOPE: passes without the fix too. It pins what the guard leaves
    /// alone: an address-shaped name still fills an empty slot, so a Person
    /// named only by such a header is stored exactly as before.
    func testIsBetterDisplayName_forEmail_addressShapedNameStillFillsEmptyName() {
        XCTAssertTrue(EmailNormalizer.isBetterDisplayName(
            "jacob.laycock@studs.com",
            than: nil,
            forEmail: "jacob.laycock@studs.com"
        ))
    }

    /// The encoded-word guard runs first: a raw encoded-word on screen is worse
    /// than an address, so a decoded address-shaped candidate still replaces it.
    ///
    /// Revert-check: moving the `isEmailAddressShapedDisplayName` guard above the
    /// `RFC2047Decoder.containsEncodedWord` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test.
    func testIsBetterDisplayName_forEmail_addressShapedNameStillReplacesEncodedWordGarbage() {
        let result = EmailNormalizer.isBetterDisplayName(
            "jose@example.com",
            than: "=?utf-8?B?Sm9zw6k=?=",
            forEmail: "jose@example.com"
        )
        XCTAssertTrue(result)
    }

    func testIsEmailAddressShapedDisplayName_addressesAndNames() {
        XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName("jacob.laycock@studs.com"))
        XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName("Jacob (jacob.laycock@studs.com)"))
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("Jacob Laycock"))
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("@jacob"))
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("Jacob @ Studs"))
    }

    /// Header extraction takes any bracketed address, but the bare pattern
    /// needs a dotted domain ending in an ASCII label, so these repeated
    /// addresses are recognized only by matching the participant's own.
    ///
    /// Revert-check: removing the `normalize(displayName) == normalize(email)`
    /// term in `EmailNormalizer.isEmailAddressShapedDisplayName(_:forEmail:)`
    /// fails this test.
    func testIsEmailAddressShapedDisplayName_forEmail_recognizesOwnAddressTheBarePatternMisses() {
        for address in ["ops@intranet", "jose@correo.españa", "ops@[192.0.2.1]"] {
            XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName(address), "Precondition: \(address)")
            XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName(address, forEmail: address), address)
        }
        XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName("OPS@Intranet", forEmail: "ops@intranet"))
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("Ops", forEmail: "ops@intranet"))
        XCTAssertFalse(
            EmailNormalizer.isEmailAddressShapedDisplayName("ops@intranet", forEmail: "admin@intranet"),
            "Another dotless address is out of reach without the participant's own"
        )
    }

    /// Revert-check: removing the `normalize(displayName) == normalize(email)`
    /// term in `EmailNormalizer.isEmailAddressShapedDisplayName(_:forEmail:)`
    /// fails this test (each address outranked the one-word name by length).
    func testIsBetterDisplayName_forEmail_ownAddressTheBarePatternMissesNeverReplacesName() {
        for (address, name) in [("ops@intranet", "Ops"), ("jose@correo.españa", "José"), ("ops@[192.0.2.1]", "Ops")] {
            XCTAssertFalse(EmailNormalizer.isBetterDisplayName(address, than: name, forEmail: address), address)
            XCTAssertTrue(EmailNormalizer.isBetterDisplayName(name, than: address, forEmail: address), address)
        }
    }

    /// Outlook writes a recipient that has no name as
    /// `"'jacob.laycock@studs.com'" <jacob.laycock@studs.com>`, and header
    /// sanitizing strips only the double quotes.
    ///
    /// Revert-check: removing the `unwrappingSingleQuotes` call in
    /// `EmailNormalizer.isEmailAddressShapedDisplayName(_:)` fails this test.
    func testIsEmailAddressShapedDisplayName_recognizesOutlookSingleQuotedAddress() {
        XCTAssertEqual(
            EmailNormalizer.extractDisplayName(from: "\"'jacob.laycock@studs.com'\" <jacob.laycock@studs.com>"),
            "'jacob.laycock@studs.com'",
            "Precondition: header sanitizing keeps the single quotes"
        )
        XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName("'jacob.laycock@studs.com'"))
        XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName(" 'jacob.laycock@studs.com' "))
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("'Jacob Laycock'"))
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("'Jacob @ Studs'"))
    }

    /// Revert-check: removing the `unwrappingSingleQuotes` call in
    /// `EmailNormalizer.isEmailAddressShapedDisplayName(_:forEmail:)` fails this
    /// test (the bare pattern misses a dotless address, and the quotes broke the
    /// match with the participant's own).
    func testIsEmailAddressShapedDisplayName_forEmail_recognizesSingleQuotedOwnDotlessAddress() {
        XCTAssertFalse(EmailNormalizer.isEmailAddressShapedDisplayName("'ops@intranet'"), "Precondition")
        XCTAssertTrue(EmailNormalizer.isEmailAddressShapedDisplayName("'ops@intranet'", forEmail: "ops@intranet"))
    }

    /// Revert-check: making `EmailNormalizer.unwrappingSingleQuotes(_:)` return
    /// its input unchanged fails this test (the quoted address split into more
    /// parts than either name and outranked it). Removing only one overload's
    /// call does not: for the participant's own address each overload's
    /// unwrap catches it alone.
    func testIsBetterDisplayName_forEmail_outlookSingleQuotedAddressNeverReplacesName() {
        let email = "jacob.laycock@studs.com"
        let quoted = "'\(email)'"
        for name in ["Jake", "Jacob Laycock"] {
            XCTAssertFalse(EmailNormalizer.isBetterDisplayName(quoted, than: name, forEmail: email), name)
            XCTAssertTrue(EmailNormalizer.isBetterDisplayName(name, than: quoted, forEmail: email), name)
        }
    }

    // MARK: - isBetterDisplayName: never better in both directions

    /// For jacob.laycock@ the real "Jake Laycock" replaced the address-derived
    /// "Jacob Laycock" (two parts each), and "Jacob Laycock" won it back as the
    /// longer name.
    ///
    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch (`newIsDerived && !existingIsDerived`) of
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test.
    func testIsBetterDisplayName_forEmail_addressDerivedNameNeverReplacesRealNameOfEqualPartCount() {
        let result = EmailNormalizer.isBetterDisplayName(
            "Jacob Laycock",
            than: "Jake Laycock",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertFalse(result)
    }

    /// HONEST SCOPE: passes without the fix too. It pins the direction the fix
    /// kept: at an equal part count the real name wins.
    func testIsBetterDisplayName_forEmail_realNameReplacesAddressDerivedNameOfEqualPartCount() {
        let result = EmailNormalizer.isBetterDisplayName(
            "Jake Laycock",
            than: "Jacob Laycock",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertTrue(result)
    }

    /// The converse of `testIsBetterDisplayName_forEmail_replacesSinglePartAddressDerivedName`.
    ///
    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch of `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails
    /// this test ("Kmthau" won back as the longer one-word name).
    func testIsBetterDisplayName_forEmail_singlePartAddressDerivedNameNeverReplacesRealName() {
        let result = EmailNormalizer.isBetterDisplayName("Kmthau", than: "Kevin", forEmail: "kmthau@example.com")
        XCTAssertFalse(result)
    }

    /// HONEST SCOPE: passes without the fix too. The guard covers only the tie:
    /// a derived name with more parts still replaces a shorter real name, the
    /// converse of `testIsBetterDisplayName_forEmail_preservesMoreCompleteAddressDerivedName`.
    func testIsBetterDisplayName_forEmail_fullerAddressDerivedNameStillReplacesShorterRealName() {
        let result = EmailNormalizer.isBetterDisplayName("John Doe", than: "John", forEmail: "john.doe@example.com")
        XCTAssertTrue(result)
    }

    /// Revert-check: restoring `new != existing && hasIntentionalCasing(new)` in
    /// place of the `newHasIntentionalCasing != hasIntentionalCasing(existing)`
    /// comparison in `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)`
    /// fails this test (the uncased name then won the base ranking on word
    /// count, while the cased one won on casing).
    func testIsBetterDisplayName_forEmail_uncasedDerivedNameNeverReplacesIntentionallyCasedOne() {
        let result = EmailNormalizer.isBetterDisplayName(
            "jacob laycock",
            than: "Jacob.Laycock",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertFalse(result)
    }

    /// Revert-check: restoring `new != existing && hasIntentionalCasing(new)` in
    /// place of the intentional-casing comparison in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (both variants have intentional casing, so each replaced the other).
    func testIsBetterDisplayName_forEmail_intentionallyCasedDerivedVariantsDoNotReplaceEachOther() {
        let email = "jacob.laycock@studs.com"
        XCTAssertFalse(EmailNormalizer.isBetterDisplayName("JACOB LAYCOCK", than: "Jacob Laycock", forEmail: email))
        XCTAssertFalse(EmailNormalizer.isBetterDisplayName("Jacob Laycock", than: "JACOB LAYCOCK", forEmail: email))
    }

    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch of `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails
    /// this test (From-then-Cc order ended on "Jacob Laycock").
    func testIsBetterDisplayName_forEmail_headerOrderDoesNotFlipBetweenRealAndAddressDerivedName() {
        let email = "jacob.laycock@studs.com"
        func fold(_ candidates: [String]) -> String? {
            candidates.reduce(nil) { stored, candidate in
                EmailNormalizer.isBetterDisplayName(candidate, than: stored, forEmail: email) ? candidate : stored
            }
        }

        XCTAssertEqual(fold(["Jake Laycock", "Jacob Laycock"]), "Jake Laycock", "From header, then a Cc name matching the address")
        XCTAssertEqual(fold(["Jacob Laycock", "Jake Laycock"]), "Jake Laycock", "To name matching the address, then a From header")
    }

    /// A pair ranked better in both directions makes the stored name follow
    /// header order. Ties (false both ways) are allowed: they keep the stored
    /// name. The failure message lists every offending pair.
    ///
    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch of `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails
    /// this test (Jacob Laycock / Jake Laycock, Kevin / Kmthau, ...), and so
    /// does restoring `new != existing && hasIntentionalCasing(new)` in place of
    /// the intentional-casing comparison (BONBONWHIMS / BonBonWhims,
    /// Jacob Laycock / JACOB LAYCOCK, ...).
    func testIsBetterDisplayName_forEmail_neverRanksBothNamesOfAPairBetter() {
        let namesByEmail: [(email: String, names: [String])] = [
            ("bonbonwhims@example.com", ["BONBONWHIMS", "Bonbonwhims", "bonbonwhims", "BonBonWhims", "Bon Bon Whims"]),
            ("jacob.laycock@studs.com", [
                "Jacob Laycock", "Jake Laycock", "Jake", "Jacob", "J. Laycock", "Jacob R. Laycock",
                "JACOB LAYCOCK", "jacob laycock", "Jacob.Laycock", "jacob.laycock",
                "jacob.laycock@studs.com", "=?utf-8?B?SmFrZQ==?="
            ]),
            ("john.doe@example.com", ["John", "John Doe", "Jonathan Doe", "Johnny", "JOHN DOE", "john_doe", "Dr. John Doe"]),
            ("kmthau@example.com", ["Kevin", "Kmthau", "kmthau", "KMTHAU", "Kevin Thau", "Kev"]),
            ("mary-jane.smith@example.com", ["Mary-Jane Smith", "Mary Jane Smith", "MJ Smith", "Mary Smith", "MARY-JANE SMITH"]),
            // Address-shaped only through the participant's own address.
            ("ops@intranet", ["Ops", "OPS", "Operations Team", "ops@intranet"])
        ]

        var betterBothWays: [String] = []
        for (email, names) in namesByEmail {
            for (index, first) in names.enumerated() {
                for second in names[(index + 1)...]
                where EmailNormalizer.isBetterDisplayName(first, than: second, forEmail: email)
                    && EmailNormalizer.isBetterDisplayName(second, than: first, forEmail: email) {
                    betterBothWays.append("\(email): \"\(first)\" / \"\(second)\"")
                }
            }
        }

        XCTAssertEqual(betterBothWays, [])
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

    /// "Jacob" is a token subset of "jacob.laycock@studs.com" (whose comparison
    /// tokens are "jacob", "laycock@studs", "com"), so only the ranking keeps
    /// the older address from upgrading the newest name.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test.
    /// HONEST SCOPE: both production callers pass only names that survived
    /// `PersonDisplayNameResolver.sanitizedExplicitDisplayName`, which already
    /// drops address-shaped names, so this pins the function's contract rather
    /// than a path sync reaches today.
    func testMergeNewestFirstHeaderDisplayName_olderAddressShapedNameNeverUpgradesNewestName() {
        let result = EmailNormalizer.mergeNewestFirstHeaderDisplayName(
            "jacob.laycock@studs.com",
            into: "Jacob",
            forEmail: "jacob.laycock@studs.com"
        )
        XCTAssertEqual(result, "Jacob")
    }

    /// A case-only variant is a token subset either way, so only the ranking
    /// decides. Both variants used to rank better than each other, so the
    /// older one always won; now neither does and the newest From name stays.
    ///
    /// Revert-check: restoring `new != existing && hasIntentionalCasing(new)` in
    /// place of the intentional-casing comparison in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test.
    func testMergeNewestFirstHeaderDisplayName_olderCaseOnlyVariantNeverReplacesNewestName() {
        let email = "jacob.laycock@studs.com"
        XCTAssertEqual(
            EmailNormalizer.mergeNewestFirstHeaderDisplayName("JACOB LAYCOCK", into: "Jacob Laycock", forEmail: email),
            "Jacob Laycock"
        )
        XCTAssertEqual(
            EmailNormalizer.mergeNewestFirstHeaderDisplayName("Jacob Laycock", into: "JACOB LAYCOCK", forEmail: email),
            "JACOB LAYCOCK"
        )
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
