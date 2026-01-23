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

    func testExtractEmail_plainEmailWithWhitespace_trimmed() {
        let result = EmailNormalizer.extractEmail(from: "  john@example.com  ")
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
}
