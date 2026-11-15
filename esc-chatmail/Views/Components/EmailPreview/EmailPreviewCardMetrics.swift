import SwiftUI

/// The text sizes, the date tile and the padding of the chat's cards, as a value: the email
/// preview cards (calendar invite, reservation, newsletter, transactional, deploy), the
/// forwarded-message card, the shared-document cards, the "Open original email" fallback and
/// the attachment cards (document, PDF, video).
///
/// The sizes were literals in each card, tuned to the iPhone, whose bubble text is 17 points.
/// The Mac's chat column draws the same cards beside 13-point bubble text, where a 17-point
/// title and a 30-point day number stood over every message around them. What differs between
/// the two is in here, so no card checks the platform: the bubble's style names the metrics
/// (`MessageBubbleStyle.previewCardMetrics`) and `MessageBubble` puts them in the environment
/// of its whole row (`EnvironmentValues.emailPreviewCardMetrics`), because a card is several
/// views below the bubble that knows the style.
///
/// Every card's text is SF Pro, the system's default design (`font(_:_:)`). The cards were
/// set in SF Rounded until 2026-11-15; `EmailPreviewCardSourceTests` keeps the rounded
/// design out of the app.
///
/// The sizes are fixed points and do not follow Dynamic Type, as before: a card's height is
/// known when its row mounts, which the transcript's anchoring depends on.
///
/// - `iOS` is the cards' literals from before they were a value, pinned field by field
///   (`EmailPreviewCardMetricsTests`), so the iPhone's cards keep their sizes when the Mac's
///   are tuned.
/// - `mac` is the same scale brought down to the Mac's text sizes, drawn off screen in the
///   test host and not yet seen in the app.
struct EmailPreviewCardMetrics: Equatable {
    /// The title of a preview card (calendar invite, reservation, newsletter, transactional,
    /// deploy).
    let titleSize: CGFloat
    /// The size under a preview card's title, and the title of a card that is one row: a
    /// transactional card's subtitle, a newsletter's snippet, a forwarded message's sender,
    /// and the title of an attachment card, of the plain shared-link card and of the "Open
    /// original email" fallback.
    let subtitleSize: CGFloat
    /// A row of a card's details (when, where, who), a newsletter's subtitle, and a forwarded
    /// message's subject and preview.
    let detailSize: CGFloat
    /// A lesser detail row, an action's link ("Open invite"), the icon beside a detail, a
    /// deploy's repository and commit, a transactional card's detail line, the plain
    /// shared-link card's host, a document attachment's size, and the kind label on a
    /// shared-file card with no thumbnail.
    let secondaryDetailSize: CGFloat
    /// The source line in a card's header, a status or action capsule, a timestamp, a
    /// forwarded message's recipients, and the plain shared-link card's address.
    let labelSize: CGFloat
    /// The amount on a transactional card.
    let amountSize: CGFloat
    /// The title of a shared-file card, which reserves two lines of it.
    let linkTitleSize: CGFloat
    /// The source line under a shared-file card's title.
    let linkSourceSize: CGFloat
    /// The month / day / weekday tile of the calendar and reservation cards.
    let dateTile: DateTile
    /// Around a preview card's content.
    let cardPadding: CGFloat
    /// The least height of the calendar and reservation cards.
    let dateCardMinHeight: CGFloat
    let transactionalCardMinHeight: CGFloat
    let deployCardMinHeight: CGFloat

    struct DateTile: Equatable {
        let size: CGSize
        let cornerRadius: CGFloat
        /// Between the tile's lines.
        let spacing: CGFloat
        let monthSize: CGFloat
        let daySize: CGFloat
        let weekdaySize: CGFloat
    }

    /// A card's font at one of these sizes: SF Pro, never the rounded design. The one way a
    /// card makes a font from the metrics; the date tile's sizes are reached through the same
    /// key path (`\.dateTile.daySize`).
    func font(_ size: KeyPath<EmailPreviewCardMetrics, CGFloat>, _ weight: Font.Weight = .regular) -> Font {
        .system(size: self[keyPath: size], weight: weight, design: .default)
    }
}

extension EmailPreviewCardMetrics {
    /// The iPhone's cards: the sizes each card had as literals.
    static let iOS = EmailPreviewCardMetrics(
        titleSize: 17,
        subtitleSize: 14,
        detailSize: 13,
        secondaryDetailSize: 12,
        labelSize: 11,
        amountSize: 28,
        linkTitleSize: 18,
        linkSourceSize: 15,
        dateTile: DateTile(
            size: CGSize(width: 70, height: 92),
            cornerRadius: 16,
            spacing: 4,
            monthSize: 12,
            daySize: 30,
            weekdaySize: 11
        ),
        cardPadding: 14,
        dateCardMinHeight: 144,
        transactionalCardMinHeight: 148,
        deployCardMinHeight: 128
    )

    /// The Mac's cards. A title is the bubble text's 13 points, semibold, and everything under
    /// it steps down from there, as the Mac's own text styles do (13, 12, 11, 10).
    static let mac = EmailPreviewCardMetrics(
        titleSize: 13,
        subtitleSize: 12,
        detailSize: 12,
        secondaryDetailSize: 11,
        labelSize: 11,
        amountSize: 20,
        linkTitleSize: 13,
        linkSourceSize: 11,
        dateTile: DateTile(
            size: CGSize(width: 54, height: 72),
            cornerRadius: 12,
            spacing: 2,
            monthSize: 10,
            daySize: 22,
            weekdaySize: 10
        ),
        cardPadding: 12,
        dateCardMinHeight: 116,
        transactionalCardMinHeight: 118,
        deployCardMinHeight: 104
    )
}

private struct EmailPreviewCardMetricsKey: EnvironmentKey {
    static let defaultValue = EmailPreviewCardMetrics.iOS
}

extension EnvironmentValues {
    /// The metrics the chat's cards draw with. The bubble's style sets them
    /// (`MessageBubbleStyle.previewCardMetrics`); a card mounted outside a bubble gets the
    /// iPhone's.
    var emailPreviewCardMetrics: EmailPreviewCardMetrics {
        get { self[EmailPreviewCardMetricsKey.self] }
        set { self[EmailPreviewCardMetricsKey.self] = newValue }
    }
}
