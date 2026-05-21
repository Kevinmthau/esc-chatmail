import XCTest
@testable import esc_chatmail

final class TransactionalPreviewBuilderTests: XCTestCase {
    private let sut = TransactionalPreviewBuilder()

    func testBuildPreview_extractsTransactionalTitleAndAmount() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
            <h2>Transaction details</h2>
            <p>Date</p>
            <p>Apr 08, 2026</p>
            <p>Status</p>
            <p>Pending</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "You paid Andrew Archer $100.00"
        )

        XCTAssertEqual(result?.title, "You paid Andrew Archer")
        XCTAssertEqual(result?.amount, "$100.00")
        XCTAssertEqual(result?.status, "Pending")
        XCTAssertEqual(result?.actionLabel, "See transaction")
        XCTAssertEqual(result?.detailLine, "Apr 08, 2026")
    }

    func testBuildPreview_extractsSingleTableDepositDeclinedNotification() {
        let html = """
        <table border="0" cellpadding="0" cellspacing="0" id="tblHeader">
            <tr><td>&nbsp;</td><td bgcolor="003C71"><font color="FFFFFF"><strong>Example National Bank</strong></font></td></tr>
            <tr><td>&nbsp;</td><td bgcolor="E3EDFF"><font color="000000"><strong>Deposit Declined</strong></font></td></tr>
            <tr><td>&nbsp;</td><td><strong>Account Number Ending: 0039</strong></td></tr>
            <tr><td>&nbsp;</td><td><strong>Example National Mobile Check Deposit</strong></td></tr>
            <tr><td>&nbsp;</td><td>
                <p>Your deposit of $10,181.90 was declined due to "Your daily deposit limit amount was exceeded".</p>
                <p>We are sorry that we are not able to accept your deposit through Example National mobile banking.</p>
                <p>Please do not respond to this message or send email to this address.</p>
            </td></tr>
        </table>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Example National Bank",
            senderEmail: "alerts@examplebank.com",
            subject: nil
        )

        XCTAssertEqual(result?.title, "Deposit Declined")
        XCTAssertEqual(result?.amount, "$10,181.90")
        XCTAssertEqual(result?.subtitle, "Account Number Ending: 0039")
        XCTAssertEqual(result?.detailLine, "Example National Mobile Check Deposit")
        XCTAssertEqual(result?.sourceLabel, "Example National Bank")
    }

    func testBuildPreview_extractsAppStoreConnectBuildMetadataAndSkipsGreeting() {
        let subject = "App Store Connect: Version 1.0 (37) for Stickys has completed processing."
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <table><tr><td>App Store Connect</td></tr></table>
            <table><tr><td>Dear Kevin Thau,</td></tr></table>
            <table><tr><td>Version 1.0 (37) for Stickys has completed processing.</td></tr></table>
            <table>
                <tr><td>App Name:</td><td>Stickys</td></tr>
                <tr><td>Version Number:</td><td>1.0</td></tr>
                <tr><td>Build Number:</td><td>37</td></tr>
            </table>
            <p>You can now use this build for TestFlight testing or submit it to the App Store.</p>
            <p><a href="https://appstoreconnect.apple.com">View in App Store Connect</a></p>
            <p><a href="https://developer.apple.com/contact">Contact us</a></p>
            <p>Privacy Policy | All rights reserved</p>
        </body>
        </html>
        """
        let bodyText = """
        App Store Connect

        Dear Kevin Thau,

        Version 1.0 (37) for Stickys has completed processing.

        App Name: Stickys
        Version Number: 1.0
        Build Number: 37

        You can now use this build for TestFlight testing or submit it to the App Store.
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            cleanedSnippet: "Dear Kevin Thau,",
            senderName: nil,
            senderEmail: "no_reply@email.apple.com",
            subject: subject
        )

        XCTAssertEqual(result?.title, subject)
        XCTAssertEqual(result?.subtitle, "Stickys • Version 1.0 • Build 37")
        XCTAssertEqual(result?.status, "Completed")
        XCTAssertNil(result?.detailLine)
        XCTAssertNil(result?.amount)
        XCTAssertNil(result?.actionLabel)
        XCTAssertEqual(result?.sourceLabel, "App Store Connect")
        XCTAssertEqual(result?.sourceDomain, "email.apple.com")
        XCTAssertFalse(result?.subtitle?.localizedCaseInsensitiveContains("dear") == true)
    }

    func testBuildPreview_ignoresVenmoPromoBannerAndPrefersAvatarImage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.venmo.com/promos/cashback-banner.png" width="600" height="240" alt="Earn up to 5% cashback banner">
            <p>Earn up to 5% cashback and earn rewards.</p>
            <img src="https://pics-v3.venmo.com/andrew-archer?width=100&height=100" width="93" height="93" alt="Andrew Archer image">
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p>:venmo_dollar:</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
            <h2>Transaction details</h2>
            <p>Date</p>
            <p>Apr 08, 2026</p>
            <p>Status</p>
            <p>Pending</p>
            <p>Payment Method</p>
            <p>Venmo balance</p>
            <p>For security reasons, you cannot unsubscribe from payment emails.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "You paid Andrew Archer $100.00"
        )

        XCTAssertEqual(result?.title, "You paid Andrew Archer")
        XCTAssertEqual(result?.imageURL, "https://pics-v3.venmo.com/andrew-archer?width=100&height=100")
        XCTAssertEqual(result?.imageStyle, .avatar)
        XCTAssertEqual(result?.detailLine, "Apr 08, 2026 • Venmo balance")
        XCTAssertNil(result?.subtitle)
    }

    func testBuildPreview_upgradesHTTPAvatarImageURLForNativePreviewLoading() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="http://pics-v3.venmo.com/andrew-archer?width=100&height=100" width="93" height="93" alt="Andrew Archer profile image">
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "You paid Andrew Archer $100.00"
        )

        XCTAssertEqual(result?.imageURL, "https://pics-v3.venmo.com/andrew-archer?width=100&height=100")
        XCTAssertEqual(result?.imageStyle, .avatar)
    }

    func testBuildPreview_rejectsDuplicateSnippetAndUsesRealSecondaryDetail() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p>For sushi dinner</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
            <h2>Transaction details</h2>
            <p>Date</p>
            <p>Apr 08, 2026</p>
            <p>Status</p>
            <p>Pending</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: "You paid Andrew Archer $100.00\nFor sushi dinner\nDate\nApr 08, 2026\nStatus\nPending",
            cleanedSnippet: "You paid Andrew Archer $100.00",
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "Payment complete"
        )

        XCTAssertEqual(result?.title, "You paid Andrew Archer")
        XCTAssertEqual(result?.amount, "$100.00")
        XCTAssertEqual(result?.subtitle, "For sushi dinner")
    }

    func testBuildPreview_extractsReservationCancellationDetails() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>El Puma (Maximes)</h1>
            <p>This reservation has been cancelled. We look forward to assisting you with future reservations.</p>
            <p>Mr. Kevin Thau</p>
            <p>Wednesday, April 29, 2026</p>
            <p>4 guests · 7:30 PM</p>
            <p>Your reservation number is 3YZ29N45F4PW</p>
            <p>experience by</p>
            <p>You are receiving this email from El Puma (Maximes) through SevenRooms</p>
        </body>
        </html>
        """
        let bodyText = """
        El Puma (Maximes)

        This reservation has been cancelled. We look forward to assisting you with future reservations.

        Mr. Kevin Thau

        Wednesday, April 29, 2026

        4 guests  ·  7:30 PM

        Your reservation number is 3YZ29N45F4PW

        experience by

        You are receiving this email from El Puma (Maximes) through SevenRooms
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "El Puma (Maximes)",
            senderEmail: "r+abc@message.sevenrooms.com",
            subject: "Reservation Cancellation for El Puma (Maximes) | Mr. Kevin Thau on 4/29/26"
        )

        XCTAssertEqual(result?.title, "Reservation Cancellation for El Puma (Maximes) | Mr. Kevin Thau on 4/29/26")
        XCTAssertEqual(result?.subtitle, "This reservation has been cancelled. We look forward to assisting you with future...")
        XCTAssertEqual(result?.status, "Cancelled")
        XCTAssertEqual(result?.detailLine, "Wednesday, April 29, 2026 • 4 guests • 7:30 PM")
        XCTAssertEqual(result?.sourceLabel, "El Puma (Maximes)")
        XCTAssertEqual(result?.sourceDomain, "message.sevenrooms.com")
    }

    func testBuildPreview_mergesReservationPartySizeAndTimeFromSeparateLines() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>El Puma (Maximes)</h1>
            <p>Reservation confirmed</p>
            <p>Wednesday, April 29, 2026</p>
            <p>4 guests</p>
            <p>7:30 PM</p>
        </body>
        </html>
        """
        let bodyText = """
        El Puma (Maximes)

        Reservation confirmed

        Wednesday, April 29, 2026

        4 guests

        7:30 PM
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "El Puma (Maximes)",
            senderEmail: "r+abc@message.sevenrooms.com",
            subject: "Reservation confirmation for El Puma (Maximes)"
        )

        XCTAssertEqual(result?.detailLine, "Wednesday, April 29, 2026 • 4 guests • 7:30 PM")
    }

    func testBuildPreview_mergesReservationTimeFromAdjacentLabelledLine() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>El Puma (Maximes)</h1>
            <p>Reservation confirmed</p>
            <p>Wednesday, April 29, 2026</p>
            <p>4 guests</p>
            <p>Reservation time 7:30 PM</p>
        </body>
        </html>
        """
        for timeLine in ["Time: 7:30 PM", "Reservation time 7:30 PM"] {
            let bodyText = """
            El Puma (Maximes)

            Reservation confirmed

            Wednesday, April 29, 2026

            4 guests

            \(timeLine)
            """

            let result = sut.buildPreview(
                canonicalHTML: html,
                bodyText: bodyText,
                senderName: "El Puma (Maximes)",
                senderEmail: "r+abc@message.sevenrooms.com",
                subject: "Reservation confirmation for El Puma (Maximes)"
            )

            XCTAssertEqual(
                result?.detailLine,
                "Wednesday, April 29, 2026 • 4 guests • 7:30 PM",
                "Expected labelled time line to merge: \(timeLine)"
            )
        }
    }

    func testBuildPreview_doesNotPairReservationPartyWithLaterCancellationTime() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>El Puma (Maximes)</h1>
            <p>Reservation confirmed</p>
            <p>Wednesday, April 29, 2026</p>
            <p>4 guests</p>
            <p>Your reservation number is 3YZ29N45F4PW</p>
            <p>Cancellations made after Tuesday, April 28, 2026</p>
            <p>5:00 PM</p>
            <p>will be charged a fee.</p>
        </body>
        </html>
        """
        let bodyText = """
        El Puma (Maximes)

        Reservation confirmed

        Wednesday, April 29, 2026

        4 guests

        Your reservation number is 3YZ29N45F4PW

        Cancellations made after Tuesday, April 28, 2026

        5:00 PM

        will be charged a fee.
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "El Puma (Maximes)",
            senderEmail: "r+abc@message.sevenrooms.com",
            subject: "Reservation confirmation for El Puma (Maximes)"
        )

        XCTAssertEqual(result?.detailLine, "Wednesday, April 29, 2026 • 4 guests")
    }

    func testBuildPreviewFromSourceUsesSnapshotActionLinksInsteadOfReparsingHTMLAnchors() {
        let source = EmailPreviewSource(
            messageId: "transactional-source-snapshot",
            sourceSignature: "sha256:snapshot",
            canonicalHTML: """
            <!DOCTYPE html>
            <html>
            <body>
                <h1>Payment complete</h1>
                <p>$24.20</p>
                <a href="https://example.com/promo">Learn more</a>
            </body>
            </html>
            """,
            plainText: nil,
            extractedText: """
            You paid Cafe Example
            $24.20
            Date
            May 5, 2026
            """,
            extractedImages: [],
            htmlSummary: EmailPreviewHTMLSummary(
                h1Text: "You paid Cafe Example",
                h2Text: nil,
                titleText: nil,
                preheaderText: nil,
                actionLinkTexts: ["View receipt"]
            ),
            classification: EmailPreviewClassification(
                kind: .transactional,
                newsletterScore: 0,
                transactionalScore: 70,
                signals: [.transactionalKeywords]
            )
        )

        let result = sut.buildPreview(
            source: source,
            senderName: "Example Pay",
            senderEmail: "receipts@example.com",
            subject: nil
        )

        XCTAssertEqual(result?.title, "You paid Cafe Example")
        XCTAssertEqual(result?.amount, "$24.20")
        XCTAssertEqual(result?.actionLabel, "View receipt")
    }
}
