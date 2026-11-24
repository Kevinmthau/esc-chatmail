import XCTest
@testable import esc_chatmail

/// The rows a scroll-driven window load asks for (`VirtualScrollWindowPolicy`):
/// the position's rows, widened to keep every realized row and some slack
/// beyond them, so a viewport taller than the position's rows keeps its
/// on-screen rows through a sliding replace (architecture review 2026-11,
/// chat-transcript-ui#1).
final class VirtualScrollWindowPolicyTests: XCTestCase {
    /// 3 rows from the position down plus a buffer of 1 on each side: the
    /// position's rows are 5 wide, and the slack kept beyond realized rows is
    /// 1 row.
    private let configuration = VirtualScrollConfiguration(
        visibleItemCount: 3,
        bufferSize: 1,
        pageSize: 3,
        preloadThreshold: 0,
        maxWindowSize: 100
    )

    /// The same, capped at the configuration's floor, 3 + 2·1 + 2·3 = 11.
    private let cappedConfiguration = VirtualScrollConfiguration(
        visibleItemCount: 3,
        bufferSize: 1,
        pageSize: 3,
        preloadThreshold: 0,
        maxWindowSize: 11
    )

    private func rows(_ startIndex: Int, _ endIndex: Int) -> VirtualScrollWindowPolicy.Rows {
        VirtualScrollWindowPolicy.Rows(startIndex: startIndex, endIndex: endIndex)
    }

    private func identity(_ index: Int) -> ChatMessageDisplayIdentity {
        .outboundSend(optimisticMessageID: "row-\(index)")
    }

    private func requestedRows(
        scrollPosition: Int,
        totalCount: Int = 200,
        configuration: VirtualScrollConfiguration? = nil,
        realizedRows: ClosedRange<Int>?,
        window: VirtualScrollWindowPolicy.Rows
    ) -> VirtualScrollWindowPolicy.Rows {
        VirtualScrollWindowPolicy.requestedRows(
            scrollPosition: scrollPosition,
            totalCount: totalCount,
            configuration: configuration ?? self.configuration,
            realizedRows: realizedRows,
            windowRows: window
        )
    }

    // MARK: - positionRows

    func testPositionRows_isTheSlidingReplacesRange() {
        XCTAssertEqual(
            VirtualScrollWindowPolicy.positionRows(
                scrollPosition: 14,
                totalCount: 40,
                configuration: configuration
            ),
            rows(13, 18)
        )
    }

    func testPositionRows_clipsToTheDataset() {
        XCTAssertEqual(
            VirtualScrollWindowPolicy.positionRows(
                scrollPosition: 0,
                totalCount: 40,
                configuration: configuration
            ),
            rows(0, 4)
        )
        XCTAssertEqual(
            VirtualScrollWindowPolicy.positionRows(
                scrollPosition: 38,
                totalCount: 40,
                configuration: configuration
            ),
            rows(37, 40)
        )
    }

    // MARK: - requestedRows

    func testRequestedRows_withNothingRealized_isThePositionRows() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: nil, window: rows(0, 30)),
            rows(13, 18)
        )
    }

    /// A viewport no taller than the position's rows (a phone's): the
    /// realized rows lie inside them and a replace is exactly what it was,
    /// slack included.
    func testRequestedRows_realizedRowsInsideThePositionRows_isThePositionRows() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 13...14, window: rows(0, 30)),
            rows(13, 18)
        )
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 13...17, window: rows(0, 30)),
            rows(13, 18)
        )
    }

    /// Scrolling down, the position is the bottom edge, and a tall viewport
    /// shows rows above it far past the buffer: they are kept, with the slack
    /// above them.
    ///
    /// Revert-check: returning `positionRows` from
    /// `VirtualScrollWindowPolicy.requestedRows` asks for 13..<18 here and
    /// drops on-screen rows 7..<13.
    func testRequestedRows_scrollingDownTallViewport_keepsTheRowsAboveThePosition() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 7...13, window: rows(0, 30)),
            rows(6, 18)
        )
    }

    /// Scrolling up, the position is the top edge, and a viewport taller
    /// than the position's rows shows rows below them: they are kept, with
    /// the slack below them.
    func testRequestedRows_scrollingUpTallViewport_keepsTheRowsBelowThePositionRows() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 10, realizedRows: 11...18, window: rows(5, 25)),
            rows(9, 20)
        )
    }

    /// Without the slack, the window ended at the viewport's edge: a row
    /// appearing there was within `preloadThreshold` of the window's end, and
    /// a reader turning back had no row beyond the edge to appear.
    ///
    /// Revert-check: dropping `bufferSize` from the two widened bounds in
    /// `VirtualScrollWindowPolicy.requestedRows` asks for 9..<19 and 7..<18.
    func testRequestedRows_tallViewport_keepsBufferRowsBeyondTheRealizedRows() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 10, realizedRows: 11...18, window: rows(0, 40)),
            rows(9, 20)
        )
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 7...13, window: rows(0, 40)),
            rows(6, 18)
        )
    }

    /// The slack and the realized rows are kept only from rows the window
    /// already holds, so a request adds no load or prepend beyond the
    /// position's own rows.
    func testRequestedRows_keepsOnlyRowsTheWindowHolds() {
        // The slack stops at the window's edge.
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 7...13, window: rows(7, 30)),
            rows(7, 18)
        )
        XCTAssertEqual(
            requestedRows(scrollPosition: 10, realizedRows: 11...18, window: rows(5, 19)),
            rows(9, 19)
        )
        // Realized rows reported outside the window are not asked for.
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 2...13, window: rows(8, 30)),
            rows(8, 18)
        )
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, realizedRows: 2...5, window: rows(8, 30)),
            rows(13, 18)
        )
    }

    func testRequestedRows_clipsToTheDataset() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 14, totalCount: 16, realizedRows: 10...20, window: rows(0, 30)),
            rows(9, 16)
        )
    }

    /// A position past the dataset's end (a count that shrank under it) asks
    /// for an empty or inverted range, which a load refuses; realized rows do
    /// not turn it into a range a load would accept.
    ///
    /// Revert-check: letting `start == end` through the guard in
    /// `VirtualScrollWindowPolicy.requestedRows` asks for 10..<20 in the
    /// second case, a load that replaces the window.
    func testRequestedRows_positionPastTheEnd_isLeftForTheLoadToRefuse() {
        XCTAssertEqual(
            requestedRows(scrollPosition: 30, totalCount: 20, realizedRows: 15...19, window: rows(10, 20)),
            rows(29, 20)
        )
        // Exactly `bufferSize` past the end: the position's rows are empty.
        XCTAssertEqual(
            requestedRows(
                scrollPosition: 30,
                totalCount: 20,
                configuration: VirtualScrollConfiguration(
                    visibleItemCount: 3,
                    bufferSize: 10,
                    pageSize: 3,
                    preloadThreshold: 0
                ),
                realizedRows: 15...19,
                window: rows(10, 35)
            ),
            rows(20, 20)
        )
    }

    /// Past the cap, the rows farthest from the position go first (the slack,
    /// then realized rows), on whichever side they are, and the position's
    /// rows stay whole.
    ///
    /// Revert-check: dropping a row above on every pass of the cap's loop in
    /// `VirtualScrollWindowPolicy.requestedRows`, whichever side is farther,
    /// asks for 49..<60 in the first case and keeps no row above the
    /// position's.
    func testRequestedRows_pastTheCap_dropsTheRowsFarthestFromThePosition() {
        // Position 50: its rows are 49..<54. Realized 30...70 with its slack
        // is 29..<72; 11 rows fit. The six kept besides the position's are the
        // nearest: 45...48 above (distances 5 to 2) and 54...55 below (4 and 5).
        XCTAssertEqual(
            requestedRows(
                scrollPosition: 50,
                configuration: cappedConfiguration,
                realizedRows: 30...70,
                window: rows(0, 200)
            ),
            rows(45, 56)
        )
        // All on one side: that side gives up its farthest rows alone.
        XCTAssertEqual(
            requestedRows(
                scrollPosition: 50,
                configuration: cappedConfiguration,
                realizedRows: 0...50,
                window: rows(0, 200)
            ),
            rows(43, 54)
        )
        XCTAssertEqual(
            requestedRows(
                scrollPosition: 50,
                configuration: cappedConfiguration,
                realizedRows: 50...120,
                window: rows(0, 200)
            ),
            rows(49, 60)
        )
    }

    // MARK: - realizedRowSpan

    func testRealizedRowSpan_placesRowsAtTheWindowStartPlusTheirPlace() {
        let published = (0..<8).map(identity)
        XCTAssertEqual(
            VirtualScrollWindowPolicy.realizedRowSpan(
                realizedRowIdentities: [identity(2), identity(5), identity(3)],
                publishedRowIdentities: published,
                windowRows: rows(10, 18)
            ),
            12...15
        )
    }

    func testRealizedRowSpan_isNilWhenNoPublishedRowIsRealized() {
        let published = (0..<8).map(identity)
        XCTAssertNil(
            VirtualScrollWindowPolicy.realizedRowSpan(
                realizedRowIdentities: [],
                publishedRowIdentities: published,
                windowRows: rows(10, 18)
            )
        )
        XCTAssertNil(
            VirtualScrollWindowPolicy.realizedRowSpan(
                realizedRowIdentities: [identity(42)],
                publishedRowIdentities: published,
                windowRows: rows(10, 18)
            )
        )
    }

    /// Published rows past the window's end (rows the row cache could not
    /// line up with it) never ask a load for a row the window does not hold.
    func testRealizedRowSpan_countsOnlyRowsInsideTheWindow() {
        let published = (0..<8).map(identity)
        XCTAssertEqual(
            VirtualScrollWindowPolicy.realizedRowSpan(
                realizedRowIdentities: [identity(1), identity(6), identity(7)],
                publishedRowIdentities: published,
                windowRows: rows(10, 17)
            ),
            11...16
        )
    }
}
