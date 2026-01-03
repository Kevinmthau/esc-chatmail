import XCTest
@testable import esc_chatmail

final class DisplayNameFormatterTests: XCTestCase {

    // MARK: - formatGroupNames Tests

    func testFormatGroupNames_emptyArray_returnsEmptyString() {
        let result = DisplayNameFormatter.formatGroupNames([])
        XCTAssertEqual(result, "")
    }

    func testFormatGroupNames_singleName_returnsFullName() {
        // Single participant shows full name (preserves company names like "Rally House")
        let result = DisplayNameFormatter.formatGroupNames(["John Smith"])
        XCTAssertEqual(result, "John Smith")
    }

    func testFormatGroupNames_singleFirstNameOnly_returnsName() {
        let result = DisplayNameFormatter.formatGroupNames(["John"])
        XCTAssertEqual(result, "John")
    }

    func testFormatGroupNames_twoNames_returnsWithAmpersand() {
        let result = DisplayNameFormatter.formatGroupNames(["John Smith", "Jane Doe"])
        XCTAssertEqual(result, "John & Jane")
    }

    func testFormatGroupNames_threeNames_returnsCommaAndAmpersand() {
        let result = DisplayNameFormatter.formatGroupNames(["John Smith", "Jane Doe", "Bob Wilson"])
        XCTAssertEqual(result, "John, Jane & Bob")
    }

    func testFormatGroupNames_fourNames_returnsAllWithCommasAndAmpersand() {
        let result = DisplayNameFormatter.formatGroupNames(["John", "Jane", "Bob", "Alice"])
        XCTAssertEqual(result, "John, Jane, Bob & Alice")
    }

    func testFormatGroupNames_fiveNames_returnsAllWithCommasAndAmpersand() {
        let result = DisplayNameFormatter.formatGroupNames(["John", "Jane", "Bob", "Alice", "Charlie"])
        XCTAssertEqual(result, "John, Jane, Bob, Alice & Charlie")
    }

    func testFormatGroupNames_emailAddresses_returnsFullEmail() {
        // Email addresses have no space, so the whole string is returned
        let result = DisplayNameFormatter.formatGroupNames(["john@example.com", "jane@example.com"])
        XCTAssertEqual(result, "john@example.com & jane@example.com")
    }

    func testFormatGroupNames_mixedNamesAndEmails_extractsFirstNames() {
        let result = DisplayNameFormatter.formatGroupNames(["John Smith", "jane@example.com"])
        XCTAssertEqual(result, "John & jane@example.com")
    }

    // MARK: - formatForRow Tests

    func testFormatForRow_emptyArrayWithFallback_returnsFallback() {
        let result = DisplayNameFormatter.formatForRow(names: [], totalCount: 0, fallback: "Unknown")
        XCTAssertEqual(result, "Unknown")
    }

    func testFormatForRow_emptyArrayWithNilFallback_returnsDefault() {
        let result = DisplayNameFormatter.formatForRow(names: [], totalCount: 0, fallback: nil)
        XCTAssertEqual(result, "No participants")
    }

    func testFormatForRow_singleName_returnsFullName() {
        let result = DisplayNameFormatter.formatForRow(names: ["John Smith"], totalCount: 1, fallback: nil)
        XCTAssertEqual(result, "John Smith")
    }

    func testFormatForRow_twoNamesNoOverflow_returnsCommaSeparated() {
        let result = DisplayNameFormatter.formatForRow(names: ["John Smith", "Jane Doe"], totalCount: 2, fallback: nil)
        XCTAssertEqual(result, "John, Jane")
    }

    func testFormatForRow_twoNamesWithOverflow_showsPlusCount() {
        let result = DisplayNameFormatter.formatForRow(names: ["John Smith", "Jane Doe"], totalCount: 5, fallback: nil)
        XCTAssertEqual(result, "John, Jane +3")
    }

    func testFormatForRow_threeNames_showsAllThree() {
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane", "Bob"], totalCount: 3, fallback: nil)
        XCTAssertEqual(result, "John, Jane, Bob")
    }

    func testFormatForRow_fourNames_showsAllFour() {
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane", "Bob", "Alice"], totalCount: 4, fallback: nil)
        XCTAssertEqual(result, "John, Jane, Bob, Alice")
    }

    func testFormatForRow_fiveNamesWithOverflow_showsFourPlusCount() {
        // Shows first 4 names + overflow count
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane", "Bob", "Alice"], totalCount: 5, fallback: nil)
        XCTAssertEqual(result, "John, Jane, Bob, Alice +1")
    }

    func testFormatForRow_manyParticipants_showsCorrectOverflow() {
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane", "Bob", "Alice"], totalCount: 10, fallback: nil)
        XCTAssertEqual(result, "John, Jane, Bob, Alice +6")
    }

    func testFormatForRow_emailAddresses_returnsFullEmail() {
        let result = DisplayNameFormatter.formatForRow(names: ["john@example.com"], totalCount: 1, fallback: nil)
        XCTAssertEqual(result, "john@example.com")
    }

    // MARK: - Edge Cases

    func testFormatGroupNames_whitespaceInName_extractsFirstPart() {
        // Single participant: returns full trimmed name
        let result = DisplayNameFormatter.formatGroupNames(["  John   Smith  "])
        XCTAssertEqual(result, "  John   Smith  ")  // Single name returns as-is
    }

    func testFormatGroupNames_whitespaceInNames_extractsFirstNames() {
        // Multiple participants with whitespace: extracts trimmed first names
        let result = DisplayNameFormatter.formatGroupNames(["  John   Smith  ", "  Jane   Doe  "])
        XCTAssertEqual(result, "John & Jane")
    }

    func testFormatForRow_totalCountLessThanNames_noOverflow() {
        // Edge case: totalCount is less than visible names (shouldn't happen in practice)
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane"], totalCount: 1, fallback: nil)
        XCTAssertEqual(result, "John, Jane")
    }

    func testFormatForRow_totalCountZeroWithNames_noOverflow() {
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane"], totalCount: 0, fallback: nil)
        XCTAssertEqual(result, "John, Jane")
    }

    // MARK: - Dr. Prefix Tests

    func testFormatGroupNames_drPrefixWithPeriod_includesTitle() {
        let result = DisplayNameFormatter.formatGroupNames(["Dr. John Smith", "Jane Doe"])
        XCTAssertEqual(result, "Dr. John & Jane")
    }

    func testFormatGroupNames_drPrefixWithoutPeriod_includesTitle() {
        let result = DisplayNameFormatter.formatGroupNames(["Dr John Smith", "Jane Doe"])
        XCTAssertEqual(result, "Dr John & Jane")
    }

    func testFormatGroupNames_multipleDoctors_includesTitles() {
        let result = DisplayNameFormatter.formatGroupNames(["Dr. John Smith", "Dr. Jane Doe", "Bob Wilson"])
        XCTAssertEqual(result, "Dr. John, Dr. Jane & Bob")
    }

    func testFormatForRow_drPrefixWithPeriod_includesTitle() {
        let result = DisplayNameFormatter.formatForRow(names: ["Dr. John Smith", "Jane Doe"], totalCount: 2, fallback: nil)
        XCTAssertEqual(result, "Dr. John, Jane")
    }

    func testFormatForRow_drPrefixWithoutPeriod_includesTitle() {
        let result = DisplayNameFormatter.formatForRow(names: ["Dr John Smith", "Jane Doe"], totalCount: 2, fallback: nil)
        XCTAssertEqual(result, "Dr John, Jane")
    }

    func testFormatGroupNames_drOnly_returnsAsIs() {
        // Edge case: name is just "Dr." with no first name
        let result = DisplayNameFormatter.formatGroupNames(["Dr.", "Jane Doe"])
        XCTAssertEqual(result, "Dr. & Jane")
    }

    func testFormatGroupNames_drInMiddleOfName_notTreatedAsTitle() {
        // "Dr" in the middle of a name should not be treated as a title
        let result = DisplayNameFormatter.formatGroupNames(["Andrew Smith", "Jane Doe"])
        XCTAssertEqual(result, "Andrew & Jane")
    }
}
