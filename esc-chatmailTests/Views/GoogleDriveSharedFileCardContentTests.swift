#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// Pins the shared Google file card to one height across its metadata states. The card mounts
/// with a title skeleton and fills the title in a pass later, so a height that followed the
/// title resized a row already in the chat transcript: 22.33pt shorter when a one-line title
/// replaced the skeleton.
///
/// HONEST SCOPE: these mount `GoogleDriveSharedFileCardContent`, the card's layout, and hand it
/// each metadata state directly. `GoogleDriveSharedFileCardView`, which owns the state and
/// loads through `GoogleDriveSharedFileMetadataProvider.shared`, is not mounted: its load
/// cannot be stubbed, and once the height is constant nothing observable from outside says
/// when the loaded title has been applied. It adds only a plain button, the load task and
/// accessibility modifiers around the content, none of which size anything.
///
/// Each test runs at the iPhone's card metrics and at the Mac's, handed to the card through the
/// environment as `MessageBubble` hands them. The Mac's are measured here on the iPhone
/// simulator, whose line of 13-point text may differ from the Mac's by a fraction of a point:
/// this suite is iOS-only and is not in `Mac.xctestplan`.
@MainActor
final class GoogleDriveSharedFileCardContentTests: XCTestCase {
    private static let cardWidth: CGFloat = 300

    private let link = SharedDocumentLink(
        id: "SharedDocumentLink.Kind.googleDoc|doc123",
        url: URL(string: "https://docs.google.com/document/d/doc123/edit")!,
        kind: .googleDoc
    )

    private static let allMetrics: [(name: String, metrics: EmailPreviewCardMetrics)] = [
        ("iOS", .iOS),
        ("mac", .mac)
    ]

    func testCardHeight_metadataResolvesToOneLineTitle_matchesSkeletonHeight() throws {
        for (name, metrics) in Self.allMetrics {
            let host = try mountCard(metadata: nil, isLoadingMetadata: true, metrics: metrics)
            let skeletonHeight = cardHeight(of: host)

            show(metadata(title: "Q3 Plan"), in: host, metrics: metrics)

            // Revert-check: sizing the skeleton on its own again, an `if`/`else` between the
            // title and the skeleton in `GoogleDriveSharedFileCardContent.titleBlock` instead of
            // the skeleton drawn over the reserved title, makes this fail (22.33pt as the card
            // was, 1pt if only the title keeps `reservesSpace`).
            XCTAssertEqual(cardHeight(of: host), skeletonHeight, accuracy: 0.01, name)
        }
    }

    func testCardHeight_titleWrapsToSecondLine_matchesOneLineTitleHeight() throws {
        for (name, metrics) in Self.allMetrics {
            let host = try mountCard(
                metadata: metadata(title: "Q3 Plan"),
                isLoadingMetadata: false,
                metrics: metrics
            )
            let oneLineHeight = cardHeight(of: host)

            // Far wider than the card at the title's 18pt and at its 13pt, so it wraps.
            show(
                metadata(title: "Quarterly planning notes for the whole product team"),
                in: host,
                metrics: metrics
            )

            // Revert-check: dropping `reservesSpace: true` from
            // `GoogleDriveSharedFileCardContent.titleBlock` makes this fail (the wrapped title
            // is a line taller than the one-line title).
            XCTAssertEqual(cardHeight(of: host), oneLineHeight, accuracy: 0.01, name)
        }
    }

    func testCardHeight_titleLongerThanTwoLines_matchesOneLineTitleHeight() throws {
        for (name, metrics) in Self.allMetrics {
            let host = try mountCard(
                metadata: metadata(title: "Q3 Plan"),
                isLoadingMetadata: false,
                metrics: metrics
            )
            let oneLineHeight = cardHeight(of: host)

            show(
                metadata(
                    title: String(
                        repeating: "Quarterly planning notes for the whole product team ",
                        count: 4
                    )
                ),
                in: host,
                metrics: metrics
            )

            // Revert-check: removing the `lineLimit` from
            // `GoogleDriveSharedFileCardContent.titleBlock` makes this fail (the title takes
            // every line it needs and the card grows with it).
            XCTAssertEqual(cardHeight(of: host), oneLineHeight, accuracy: 0.01, name)
        }
    }

    /// The Mac's card is the iPhone's with smaller text, so it is the shorter of the two: the
    /// metrics reach the card through the environment.
    ///
    /// Revert-check: reading `EmailPreviewCardMetrics.iOS` in place of the environment's value
    /// in `GoogleDriveSharedFileCardContent` makes this fail (the two heights are equal).
    func testCardHeight_atTheMacsMetrics_isLessThanAtTheIPhones() throws {
        let iOSHeight = cardHeight(of: try mountCard(metadata: nil, isLoadingMetadata: true, metrics: .iOS))
        let macHeight = cardHeight(of: try mountCard(metadata: nil, isLoadingMetadata: true, metrics: .mac))

        XCTAssertLessThan(macHeight, iOSHeight)
    }

    /// The title's skeleton is two bars over the two reserved title lines, one at the top and
    /// one at the bottom. They overlap unless the two lines are at least two bars tall.
    ///
    /// HONEST SCOPE: this measures two reserved lines of the title's font, not the bars'
    /// frames in the mounted card; it reads the font and the bar's height from the card's own
    /// statics, which the card's body draws with.
    ///
    /// Revert-check: returning a fixed `18` from
    /// `GoogleDriveSharedFileCardContent.titleSkeletonBarHeight(_:)` makes the Mac's assertion
    /// fail (two lines of its 13pt title are less than 36pt).
    func testTitleSkeleton_twoBars_fitTheTwoReservedTitleLines() throws {
        for (name, metrics) in Self.allMetrics {
            let reservedTitle = try mountInTestWindow(
                Text(" ")
                    .font(GoogleDriveSharedFileCardContent.titleFont(metrics))
                    .lineLimit(2, reservesSpace: true)
            )
            let reservedHeight = reservedTitle.sizeThatFits(
                in: CGSize(width: Self.cardWidth, height: .greatestFiniteMagnitude)
            ).height

            XCTAssertGreaterThanOrEqual(
                reservedHeight,
                2 * GoogleDriveSharedFileCardContent.titleSkeletonBarHeight(metrics),
                name
            )
        }
    }

    // MARK: - Helpers

    /// No thumbnail, so the preview area starts no image load.
    private func metadata(title: String) -> GoogleDriveSharedFileMetadata {
        GoogleDriveSharedFileMetadata(title: title, thumbnailURL: nil)
    }

    private func mountCard(
        metadata: GoogleDriveSharedFileMetadata?,
        isLoadingMetadata: Bool,
        metrics: EmailPreviewCardMetrics
    ) throws -> UIHostingController<CardUnderTest> {
        try mountInTestWindow(
            CardUnderTest(
                link: link,
                metadata: metadata,
                isLoadingMetadata: isLoadingMetadata,
                metrics: metrics
            )
        )
    }

    /// Moves the mounted card to the resolved state, as the metadata load does.
    private func show(
        _ metadata: GoogleDriveSharedFileMetadata,
        in host: UIHostingController<CardUnderTest>,
        metrics: EmailPreviewCardMetrics
    ) {
        host.rootView = CardUnderTest(
            link: link,
            metadata: metadata,
            isLoadingMetadata: false,
            metrics: metrics
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    private func cardHeight(of host: UIHostingController<CardUnderTest>) -> CGFloat {
        host.sizeThatFits(
            in: CGSize(width: Self.cardWidth, height: .greatestFiniteMagnitude)
        ).height
    }
}

/// The card with its metrics in the environment, where `MessageBubble` puts them.
private struct CardUnderTest: View {
    let link: SharedDocumentLink
    let metadata: GoogleDriveSharedFileMetadata?
    let isLoadingMetadata: Bool
    let metrics: EmailPreviewCardMetrics

    var body: some View {
        GoogleDriveSharedFileCardContent(
            link: link,
            metadata: metadata,
            isLoadingMetadata: isLoadingMetadata
        )
        .environment(\.emailPreviewCardMetrics, metrics)
    }
}
#endif
