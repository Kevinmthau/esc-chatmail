import Foundation

/// How the transcript groups its rows into runs (`docs/mac-imessage-ui-plan.md`, PR 4).
enum ChatTranscriptRunPolicy {
    /// - Parameters:
    ///   - isFirstFromSender: `ChatMessageRowGrouping.isFirstFromSender`.
    ///   - isLastFromSender: `ChatMessageRowGrouping.isLastFromSender`.
    ///   - previousDate: the date of the message before this one, nil for the conversation's
    ///     first message. Read only by a style with time lines.
    ///   - nextDate: the date of the message after this one, nil for the newest.
    static func placement(
        style: MessageBubbleStyle,
        isFirstFromSender: Bool,
        isLastFromSender: Bool,
        date: Date,
        previousDate: Date?,
        nextDate: Date?,
        calendar: Calendar
    ) -> ChatTranscriptRunPlacement {
        guard style.showsTimestampSeparators else {
            // The grouping the transcript had before a style had runs: only the avatar
            // follows it.
            return ChatTranscriptRunPlacement(
                startsRun: true,
                endsRun: isLastFromSender,
                separatorDate: nil,
                topPadding: 0
            )
        }

        // A time line breaks a run even between two messages from one sender: the bubble
        // before it gets its tail and the one after it its sender's name, as in Messages.
        let hasSeparator = ChatTimestampSeparatorPolicy.showsSeparator(
            previous: previousDate,
            current: date,
            calendar: calendar
        )
        let nextHasSeparator = nextDate.map {
            ChatTimestampSeparatorPolicy.showsSeparator(previous: date, current: $0, calendar: calendar)
        } ?? false
        let startsRun = isFirstFromSender || hasSeparator
        return ChatTranscriptRunPlacement(
            startsRun: startsRun,
            endsRun: isLastFromSender || nextHasSeparator,
            separatorDate: hasSeparator ? date : nil,
            // The time line brings its own space.
            topPadding: startsRun && !hasSeparator ? style.runTopPadding : 0
        )
    }
}
