import Foundation

/// Extracts restaurant-reservation preview details (date • party size • time,
/// and cancellation subtitles) from a transactional email's text lines.
///
/// Extracted from `TransactionalPreviewBuilder` so the reservation-specific
/// parsing rules live in one focused, independently testable unit. The shared
/// text helpers it still relies on — line truncation, the builder's
/// `normalizeLine` normalizer, and its `isLikelyDate` check — are injected so the
/// extractor carries no builder state.
struct ReservationPreviewExtractor {
    private let lineProcessor: PreviewLineProcessor
    private let normalizeLine: (String?) -> String?
    private let isLikelyDate: (String) -> Bool

    init(
        lineProcessor: PreviewLineProcessor,
        normalizeLine: @escaping (String?) -> String?,
        isLikelyDate: @escaping (String) -> Bool
    ) {
        self.lineProcessor = lineProcessor
        self.normalizeLine = normalizeLine
        self.isLikelyDate = isLikelyDate
    }

    /// A "date • party size • time" detail line assembled from reservation
    /// content, or `nil` when the lines are not a reservation.
    func detailLine(from lines: [String]) -> String? {
        let combinedText = lines.joined(separator: "\n").lowercased()
        guard combinedText.contains("reservation") else {
            return nil
        }

        var dateLine: String?
        var dateLineIndex: Int?
        var partyLine: String?
        var partyLineIndex: Int?

        for (index, line) in lines.enumerated() {
            let normalized = PreviewTextUtilities.normalizedText(line)
            guard !normalized.isEmpty else {
                continue
            }

            if dateLine == nil, isLikelyDate(normalized) {
                dateLine = normalized
                dateLineIndex = index
            }

            if partyLine == nil, let candidate = reservationPartySize(in: normalized) {
                partyLine = candidate
                partyLineIndex = index
            }
        }

        var timeLine: String?
        for (index, line) in lines.enumerated() {
            let normalized = PreviewTextUtilities.normalizedText(line)
            guard !normalized.isEmpty else {
                continue
            }

            if timeLine == nil,
               let candidate = reservationTime(in: normalized),
               isReservationTimeLine(
                index: index,
                line: normalized,
                dateLineIndex: dateLineIndex,
                partyLineIndex: partyLineIndex
               ) {
                timeLine = candidate
            }
        }

        let segments = [dateLine, partyLine, timeLine].compactMap { $0 }
        guard !segments.isEmpty else {
            return nil
        }

        return lineProcessor.truncate(segments.joined(separator: " • "), limit: 90)
    }

    /// A reservation-cancellation subtitle, or `nil` when no cancellation line is
    /// present (excluding values already used elsewhere in the preview).
    func subtitle(from lines: [String], excluding excludedValues: Set<String>) -> String? {
        for line in lines {
            guard let candidate = normalizeLine(line) else {
                continue
            }

            let comparable = PreviewTextUtilities.normalizedComparableText(candidate)
            let isReservationCancellation =
                comparable.contains("reservation has been cancelled") ||
                comparable.contains("reservation has been canceled")
            guard !excludedValues.contains(comparable),
                  isReservationCancellation else {
                continue
            }

            return lineProcessor.truncate(candidate, limit: 90)
        }

        return nil
    }

    private func reservationPartySize(in line: String) -> String? {
        guard let range = line.range(
            of: #"\b\d+\s+(?:guest|guests|person|people)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        return normalizedReservationPartyTimeLine(String(line[range]))
    }

    private func isReservationTimeLine(index: Int, line: String, dateLineIndex: Int?, partyLineIndex: Int?) -> Bool {
        if index == dateLineIndex || index == partyLineIndex {
            return true
        }

        guard isStandaloneReservationTime(line) || isLabelledReservationTime(line) else {
            return false
        }

        return [dateLineIndex, partyLineIndex]
            .compactMap { $0 }
            .contains { abs($0 - index) == 1 }
    }

    private func isStandaloneReservationTime(_ line: String) -> Bool {
        line.range(
            of: #"^\d{1,2}:\d{2}\s*(?:AM|PM)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isLabelledReservationTime(_ line: String) -> Bool {
        line.range(
            of: #"^(?:reservation\s+)?time(?:\s*:\s*|\s+)\d{1,2}:\d{2}\s*(?:AM|PM)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func reservationTime(in line: String) -> String? {
        guard let range = line.range(
            of: #"\b\d{1,2}:\d{2}\s*(?:AM|PM)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        return normalizedReservationPartyTimeLine(String(line[range]))
    }

    private func normalizedReservationPartyTimeLine(_ line: String) -> String {
        PreviewTextUtilities.normalizedText(line)
            .replacingOccurrences(of: "⋅", with: " • ")
            .replacingOccurrences(of: "·", with: " • ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
