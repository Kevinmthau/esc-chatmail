import XCTest
@testable import esc_chatmail

/// How the transcript groups rows into runs and what a row draws above itself
/// (`ChatTranscriptRunPolicy`). Pure, so these run in the iOS suite and in `Mac.xctestplan`.
final class ChatTranscriptRunPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private let noon = Date(timeIntervalSince1970: 1_794_500_000)

    private func placement(
        _ style: MessageBubbleStyle,
        isFirstFromSender: Bool = false,
        isLastFromSender: Bool = false,
        previousAgo: TimeInterval? = 60,
        nextIn: TimeInterval? = 60
    ) -> ChatTranscriptRunPlacement {
        ChatTranscriptRunPolicy.placement(
            style: style,
            isFirstFromSender: isFirstFromSender,
            isLastFromSender: isLastFromSender,
            date: noon,
            previousDate: previousAgo.map { noon.addingTimeInterval(-$0) },
            nextDate: nextIn.map { noon.addingTimeInterval($0) },
            calendar: calendar
        )
    }

    // MARK: - The iPhone's transcript

    /// The iPhone's rows had no lead-in and no runs: only the avatar followed
    /// `isLastFromSender`. Whatever the dates around a row are, that is still all it gets.
    ///
    /// Revert-check: deleting the `showsTimestampSeparators` guard from `placement` makes this
    /// fail: the iPhone's rows would grow time lines and run padding.
    func testStandard_noTimeLineNoPadding_andOnlyTheAvatarFollowsTheGrouping() {
        for isLast in [true, false] {
            for previousAgo: TimeInterval? in [nil, 60, 86_400 * 3] {
                let row = placement(
                    .standard,
                    isFirstFromSender: true,
                    isLastFromSender: isLast,
                    previousAgo: previousAgo,
                    nextIn: 86_400 * 3
                )
                XCTAssertEqual(row, ChatTranscriptRunPlacement(
                    startsRun: true,
                    endsRun: isLast,
                    separatorDate: nil,
                    topPadding: 0
                ))
            }
        }
    }

    /// Revert-check: changing any field of `ChatTranscriptRunPlacement.alone` makes this fail.
    func testAlone_isARowWithNothingAboveItThatEndsItsRun() {
        XCTAssertEqual(
            ChatTranscriptRunPlacement.alone,
            ChatTranscriptRunPlacement(startsRun: true, endsRun: true, separatorDate: nil, topPadding: 0)
        )
    }

    // MARK: - The Mac's transcript

    /// Revert-check: returning `style.runTopPadding` for every row makes this fail.
    func testMac_insideARun_nothingAbove() {
        XCTAssertEqual(
            placement(.mac),
            ChatTranscriptRunPlacement(startsRun: false, endsRun: false, separatorDate: nil, topPadding: 0)
        )
    }

    /// Revert-check: returning 0 for `topPadding` makes this fail: runs would sit as close
    /// together as the bubbles inside one.
    func testMac_firstRowOfARun_hasTheRunPaddingAbove() {
        let row = placement(.mac, isFirstFromSender: true)
        XCTAssertTrue(row.startsRun)
        XCTAssertNil(row.separatorDate)
        XCTAssertEqual(row.topPadding, MessageBubbleStyle.mac.runTopPadding)
    }

    /// Revert-check: `separatorDate: nil` in the Mac branch makes this fail; so does adding
    /// the run padding to a row with a time line.
    func testMac_afterALongGap_timeLineAndNoRunPadding() {
        let row = placement(.mac, isFirstFromSender: true, previousAgo: 7200)
        XCTAssertEqual(row.separatorDate, noon)
        XCTAssertEqual(row.topPadding, 0)
    }

    /// Revert-check: `startsRun: isFirstFromSender` in the Mac branch makes this fail: a
    /// group's sender would go unnamed after a time line.
    func testMac_timeLineStartsARunEvenFromTheSameSender() {
        let row = placement(.mac, isFirstFromSender: false, previousAgo: 7200)
        XCTAssertTrue(row.startsRun)
        XCTAssertEqual(row.separatorDate, noon)
    }

    /// Revert-check: `endsRun: isLastFromSender` in the Mac branch makes this fail: the bubble
    /// before a time line would have no tail.
    func testMac_rowBeforeATimeLineEndsItsRun() {
        XCTAssertTrue(placement(.mac, isLastFromSender: false, nextIn: 7200).endsRun)
        XCTAssertFalse(placement(.mac, isLastFromSender: false, nextIn: 60).endsRun)
        XCTAssertTrue(placement(.mac, isLastFromSender: true, nextIn: 60).endsRun)
    }

    /// Revert-check: treating a nil `nextDate` as a separator makes the second assertion fail.
    func testMac_conversationsFirstAndNewestRows() {
        let first = placement(.mac, isFirstFromSender: true, previousAgo: nil)
        XCTAssertEqual(first.separatorDate, noon)

        // The newest row ends its run by the grouping alone; no next row means no time line
        // after it.
        XCTAssertFalse(placement(.mac, isLastFromSender: false, nextIn: nil).endsRun)
    }
}
