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
@MainActor
final class GoogleDriveSharedFileCardContentTests: XCTestCase {
    private static let cardWidth: CGFloat = 300

    private let link = SharedDocumentLink(
        id: "SharedDocumentLink.Kind.googleDoc|doc123",
        url: URL(string: "https://docs.google.com/document/d/doc123/edit")!,
        kind: .googleDoc
    )

    func testCardHeight_metadataResolvesToOneLineTitle_matchesSkeletonHeight() throws {
        let host = try mountCard(metadata: nil, isLoadingMetadata: true)
        let skeletonHeight = cardHeight(of: host)

        show(metadata(title: "Q3 Plan"), in: host)

        // Revert-check: sizing the skeleton on its own again, an `if`/`else` between the title
        // and the skeleton in `GoogleDriveSharedFileCardContent.titleBlock` instead of the
        // skeleton drawn over the reserved title, makes this fail (22.33pt as the card was, 1pt
        // if only the title keeps `reservesSpace`).
        XCTAssertEqual(cardHeight(of: host), skeletonHeight, accuracy: 0.01)
    }

    func testCardHeight_titleWrapsToSecondLine_matchesOneLineTitleHeight() throws {
        let host = try mountCard(metadata: metadata(title: "Q3 Plan"), isLoadingMetadata: false)
        let oneLineHeight = cardHeight(of: host)

        // Far wider than the card at the title's 18pt, so it wraps.
        show(metadata(title: "Quarterly planning notes for the whole product team"), in: host)

        // Revert-check: dropping `reservesSpace: true` from
        // `GoogleDriveSharedFileCardContent.titleBlock` makes this fail (the wrapped title is
        // a line taller than the one-line title).
        XCTAssertEqual(cardHeight(of: host), oneLineHeight, accuracy: 0.01)
    }

    func testCardHeight_titleLongerThanTwoLines_matchesOneLineTitleHeight() throws {
        let host = try mountCard(metadata: metadata(title: "Q3 Plan"), isLoadingMetadata: false)
        let oneLineHeight = cardHeight(of: host)

        show(
            metadata(
                title: String(
                    repeating: "Quarterly planning notes for the whole product team ",
                    count: 4
                )
            ),
            in: host
        )

        // Revert-check: removing the `lineLimit` from
        // `GoogleDriveSharedFileCardContent.titleBlock` makes this fail (the title takes every
        // line it needs and the card grows with it).
        XCTAssertEqual(cardHeight(of: host), oneLineHeight, accuracy: 0.01)
    }

    // MARK: - Helpers

    /// No thumbnail, so the preview area starts no image load.
    private func metadata(title: String) -> GoogleDriveSharedFileMetadata {
        GoogleDriveSharedFileMetadata(title: title, thumbnailURL: nil)
    }

    private func mountCard(
        metadata: GoogleDriveSharedFileMetadata?,
        isLoadingMetadata: Bool
    ) throws -> UIHostingController<GoogleDriveSharedFileCardContent> {
        try mountInTestWindow(
            GoogleDriveSharedFileCardContent(
                link: link,
                metadata: metadata,
                isLoadingMetadata: isLoadingMetadata
            )
        )
    }

    /// Moves the mounted card to the resolved state, as the metadata load does.
    private func show(
        _ metadata: GoogleDriveSharedFileMetadata,
        in host: UIHostingController<GoogleDriveSharedFileCardContent>
    ) {
        host.rootView = GoogleDriveSharedFileCardContent(
            link: link,
            metadata: metadata,
            isLoadingMetadata: false
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    private func cardHeight(
        of host: UIHostingController<GoogleDriveSharedFileCardContent>
    ) -> CGFloat {
        host.sizeThatFits(
            in: CGSize(width: Self.cardWidth, height: .greatestFiniteMagnitude)
        ).height
    }
}
