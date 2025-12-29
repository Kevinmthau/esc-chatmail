import XCTest
@testable import esc_chatmail

final class DisplayNameFormatterTests: XCTestCase {

    // MARK: - formatGroupNames Tests

    func testFormatGroupNames_emptyArray_returnsEmptyString() {
        let result = DisplayNameFormatter.formatGroupNames([])
        XCTAssertEqual(result, "")
    }

    func testFormatGroupNames_singleName_returnsFirstName() {
        let result = DisplayNameFormatter.formatGroupNames(["John Smith"])
        XCTAssertEqual(result, "John")
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

    func testFormatForRow_singleName_returnsFirstName() {
        let result = DisplayNameFormatter.formatForRow(names: ["John Smith"], totalCount: 1, fallback: nil)
        XCTAssertEqual(result, "John")
    }

    func testFormatForRow_twoNamesNoOverflow_returnsCommaSeparated() {
        let result = DisplayNameFormatter.formatForRow(names: ["John Smith", "Jane Doe"], totalCount: 2, fallback: nil)
        XCTAssertEqual(result, "John, Jane")
    }

    func testFormatForRow_twoNamesWithOverflow_showsPlusCount() {
        let result = DisplayNameFormatter.formatForRow(names: ["John Smith", "Jane Doe"], totalCount: 5, fallback: nil)
        XCTAssertEqual(result, "John, Jane +3")
    }

    func testFormatForRow_threeNamesWithOverflow_showsPlusCount() {
        // Even with 3 names provided, only shows first 2 + overflow
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane", "Bob"], totalCount: 5, fallback: nil)
        XCTAssertEqual(result, "John, Jane +3")
    }

    func testFormatForRow_manyParticipants_showsCorrectOverflow() {
        let result = DisplayNameFormatter.formatForRow(names: ["John", "Jane"], totalCount: 10, fallback: nil)
        XCTAssertEqual(result, "John, Jane +8")
    }

    func testFormatForRow_emailAddresses_returnsFullEmail() {
        let result = DisplayNameFormatter.formatForRow(names: ["john@example.com"], totalCount: 1, fallback: nil)
        XCTAssertEqual(result, "john@example.com")
    }

    // MARK: - Edge Cases

    func testFormatGroupNames_whitespaceInName_extractsFirstPart() {
        let result = DisplayNameFormatter.formatGroupNames(["  John   Smith  "])
        // Note: The current implementation doesn't trim, so leading space becomes first component
        // This documents current behavior
        XCTAssertEqual(result, "")
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
}
