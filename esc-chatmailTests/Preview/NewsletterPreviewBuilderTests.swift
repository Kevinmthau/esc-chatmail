import XCTest
@testable import esc_chatmail

final class NewsletterPreviewBuilderTests: XCTestCase {
    private let sut = NewsletterPreviewBuilder()

    func testBuildPreview_extractsHeroTitleAndSnippet() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/logo.png" width="48" height="48" alt="Logo">
            <img src="https://cdn.example.com/hero-banner.jpg" width="640" height="320" alt="Hero banner">
            <h1>Markets are back in motion</h1>
            <p>Stocks rallied sharply after fresh inflation data came in below expectations.</p>
            <p>Here is what matters today, what moved overnight, and what to watch next.</p>
            <p><a href="https://example.com/read-more">Read more</a></p>
            <p>Manage preferences or unsubscribe at any time.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "news@morningbrew.com",
            subject: "Morning Brew"
        )

        XCTAssertEqual(result?.title, "Markets are back in motion")
        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/hero-banner.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
        XCTAssertEqual(result?.sourceDomain, "morningbrew.com")
        XCTAssertTrue(result?.snippet.contains("Stocks rallied sharply") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("unsubscribe") == true)
    }

    func testBuildPreview_skipsUnsafeAndTrackingHeroCandidates() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="javascript:alert('xss')" width="640" height="320" alt="Hero banner">
            <img src="https://tracking.example.com/open.gif" width="640" height="320" alt="Hero banner">
            <img src="https://cdn.example.com/daily-cover.jpg" width="640" height="320" alt="Cover image">
            <h1>Daily briefing</h1>
            <p>The five stories shaping markets before the opening bell.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Daily briefing"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/daily-cover.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
    }

    func testBuildPreview_omitsHeroWhenOnlyTinyOrSuspiciousImagesExist() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/logo.png" width="48" height="48" alt="Brand logo">
            <img src="https://cdn.example.com/social-icon.png" width="64" height="64" class="social-icon">
            <h1>Weekend edit</h1>
            <p>Ideas for cooking, reading, and getting outside this weekend.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Weekend edit"
        )

        XCTAssertNil(result?.heroImageURL)
        XCTAssertEqual(result?.title, "Weekend edit")
    }

    func testBuildPreview_marksWideHeroImageForAspectFitPresentation() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/briefing-banner.jpg" width="900" height="300" alt="Morning briefing banner">
            <h1>Morning markets briefing</h1>
            <p>The setup into the open is calmer, but treasury yields are still driving sentiment.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Morning markets briefing"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/briefing-banner.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fit)
    }

    func testBuildPreview_omitsExtremelyWidePromotionalBannerHero() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/membership-banner.jpg" width="665" height="142" alt="Membership banner">
            <h1>Spring Stationery Refresh</h1>
            <p>Fresh boxed stationery, thank-you notes, and personalized desk sets just landed.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "create@papersource.com",
            subject: "The Latest from Paper Source"
        )

        XCTAssertNil(result?.heroImageURL)
    }

    func testBuildPreview_prefersStandardHeroImageOverWideBannerFallback() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/opening-banner.jpg" width="900" height="300" alt="Opening banner">
            <img src="https://cdn.example.com/lead-story-photo.jpg" width="640" height="360" alt="Lead story hero">
            <h1>Rates cool as inflation slows</h1>
            <p>Stocks climbed after the latest CPI report came in softer than expected.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "briefing@example.com",
            subject: "Opening bell"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/lead-story-photo.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
    }

    func testBuildPreview_prefersContentHeroOverMailchimpHeaderImage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <table class="mcnImageBlock">
                <tr>
                    <td>
                        <img src="https://gallery.mailchimp.com/list/images/eataly-header.jpg" width="564" style="max-width: 1302px;" class="mcnImage">
                    </td>
                </tr>
            </table>
            <table class="mcnTextBlock">
                <tr><td>SHOP | EVENTS | WINE CLUB</td></tr>
            </table>
            <table class="mcnDividerBlock"><tr><td></td></tr></table>
            <table class="mcnImageBlock">
                <tr>
                    <td>
                        <img src="https://mcusercontent.com/list/images/elena-walch-hero.jpg" width="564" style="max-width: 800px;" class="mcnImage">
                    </td>
                </tr>
            </table>
            <p>In the heart of Alto Adige, Elena Walch makes wines shaped by mountain air, mineral soils, and a precise estate vision.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Eataly Vino",
            senderEmail: "thewineshop@eataly.com",
            subject: "Elena Walch: Bottled Alps"
        )

        XCTAssertEqual(result?.heroImageURL, "https://mcusercontent.com/list/images/elena-walch-hero.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
    }

    func testBuildPreview_handlesAbsurdImageDimensionsWithoutOverflow() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/hero.jpg" width="3037000500" height="3037000500" alt="Hero image">
            <h1>Large dimension test</h1>
            <p>This should still build a preview without crashing on malformed image metadata.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Large dimension test"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/hero.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
    }

    func testBuildPreview_fallsBackToSubjectAndStopsBeforeFooter() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p>Top analysis from our editors, selected for this week's issue.</p>
            <p>Three trends are driving the market and the first one is already underway.</p>
            <p>View in browser</p>
            <p>Privacy policy</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "dispatch@weekly-ledger.com",
            subject: "Weekly Dispatch"
        )

        XCTAssertEqual(result?.title, "Weekly Dispatch")
        XCTAssertEqual(result?.sourceDomain, "weekly-ledger.com")
        XCTAssertTrue(result?.snippet.contains("Top analysis from our editors") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("privacy policy") == true)
    }

    func testBuildPreview_prefersCleanedSnippetAndSenderNameWhenPlainTextLooksPoisoned() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/membership-banner.jpg" width="665" height="142" alt="Membership banner">
            <h1>Spring Stationery Refresh</h1>
            <p>Fresh boxed stationery, thank-you notes, and personalized desk sets just landed.</p>
            <p>Discover new designs for gifting, correspondence, and everyday writing.</p>
            <p><a href="https://example.com/shop-now">Shop now</a></p>
            <p>Terms and Conditions.</p>
        </body>
        </html>
        """

        let poisonedBodyText = """
        The Latest from Paper Source

        96

        *{box-sizing:border-box}body{margin:0;padding:0}a[x-apple-data-detectors]{color:inherit!important;text-decoration:inherit!important}#MessageViewBody a{color:inherit;text-decoration:none}
        *Terms and Conditions. https://www.papersource.com/pages/membership
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: poisonedBodyText,
            cleanedSnippet: "Fresh boxed stationery, thank-you notes, and personalized desk sets just landed. Discover new designs for gifting, correspondence, and everyday writing.",
            senderName: "Paper Source",
            senderEmail: "create@e.papersource.com",
            subject: "The Latest from Paper Source"
        )

        XCTAssertEqual(result?.title, "Spring Stationery Refresh")
        XCTAssertEqual(result?.sourceLabel, "Paper Source")
        XCTAssertTrue(result?.snippet.contains("Fresh boxed stationery") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("box-sizing") == true)
        XCTAssertFalse(result?.snippet.contains("96") == true)
    }

    func testBuildPreview_stripsLeadingTitleFromPreferredCleanedSnippet() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Spring Stationery Refresh</h1>
            <p>Fresh boxed stationery, thank-you notes, and personalized desk sets just landed.</p>
            <p>Discover new designs for gifting, correspondence, and everyday writing.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "Spring Stationery Refresh: Fresh boxed stationery, thank-you notes, and personalized desk sets just landed. Discover new designs for gifting, correspondence, and everyday writing.",
            senderName: "Paper Source",
            senderEmail: "create@papersource.com",
            subject: "The Latest from Paper Source"
        )

        XCTAssertEqual(result?.title, "Spring Stationery Refresh")
        XCTAssertTrue(result?.snippet.hasPrefix("Fresh boxed stationery") == true)
        XCTAssertFalse(result?.snippet.hasPrefix("Spring Stationery Refresh") == true)
    }

    func testBuildPreview_trimsFooterFromPreferredCleanedSnippetInsteadOfDiscardingIt() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/membership-banner.jpg" width="665" height="142" alt="Membership banner">
            <h1>Spring Stationery Refresh</h1>
            <p>Terms and Conditions.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "Fresh boxed stationery, thank-you notes, and personalized desk sets just landed. Discover new designs for gifting, correspondence, and everyday writing. Unsubscribe or manage preferences anytime.",
            senderName: "Paper Source",
            senderEmail: "create@papersource.com",
            subject: "The Latest from Paper Source"
        )

        XCTAssertEqual(result?.title, "Spring Stationery Refresh")
        XCTAssertTrue(result?.snippet.contains("Fresh boxed stationery") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("unsubscribe") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("manage preferences") == true)
    }

    func testBuildPreview_fallsBackToHTMLWhenPlainTextLooksPoisonedAndNoCleanedSnippetExists() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Spring Stationery Refresh</h1>
            <p>Fresh boxed stationery, thank-you notes, and personalized desk sets just landed.</p>
            <p>Discover new designs for gifting, correspondence, and everyday writing.</p>
            <p>Terms and Conditions.</p>
        </body>
        </html>
        """

        let poisonedBodyText = """
        The Latest from Paper Source

        96

        *{box-sizing:border-box}body{margin:0;padding:0}a[x-apple-data-detectors]{color:inherit!important;text-decoration:inherit!important}#MessageViewBody a{color:inherit;text-decoration:none}
        *Terms and Conditions. https://www.papersource.com/pages/membership
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: poisonedBodyText,
            senderEmail: "create@e.papersource.com",
            subject: "The Latest from Paper Source"
        )

        XCTAssertEqual(result?.title, "Spring Stationery Refresh")
        XCTAssertEqual(result?.sourceLabel, "Papersource")
        XCTAssertTrue(result?.snippet.contains("Fresh boxed stationery") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("box-sizing") == true)
        XCTAssertFalse(result?.snippet.contains("96") == true)
    }

    func testBuildPreview_prefersPreheaderTitleAndRejectsFooterSnippetNoise() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>The Latest from Paper Source</title></head>
        <body>
            <div class="preheader">Spring Stationery Refresh</div>
            <img src="https://cdn.example.com/membership-banner.jpg" width="665" height="142" alt="Membership banner">
            <p>Join Our Community on Social</p>
            <p>Questions? Contact Us!</p>
            <p>Terms and Conditions. Free shipping on orders $50 or more valid within the contiguous United States.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "&#8202; Join Our Community on Social *Terms and Conditions. Free shipping on orders $50 or more valid within the contiguous United States.",
            senderName: "Paper Source",
            senderEmail: "create@e.papersource.com",
            subject: "The Latest from Paper Source"
        )

        XCTAssertEqual(result?.title, "Spring Stationery Refresh")
        XCTAssertEqual(result?.sourceLabel, "Paper Source")
        XCTAssertFalse(result?.snippet.lowercased().contains("join our community") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("terms and conditions") == true)
        XCTAssertFalse(result?.snippet.contains("&#8202;") == true)
    }
}

@MainActor
final class EmailContentSectionTests: XCTestCase {
    private var testStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
    }

    override func tearDown() {
        testStack = nil
        super.tearDown()
    }

    func testMakeLoadKeyIncludesCleanedSnippet() {
        let context = testStack.viewContext
        let message = MessageBuilder()
            .withId("message-id")
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Sender")
            .build(in: context)

        message.cleanedSnippet = "Original cleaned snippet"
        let initialKey = EmailContentSection.makeLoadKey(
            for: ChatMessageRowModelMapper.map(message),
            isDarkMode: false
        )

        message.cleanedSnippet = "Updated cleaned snippet"
        let updatedKey = EmailContentSection.makeLoadKey(
            for: ChatMessageRowModelMapper.map(message),
            isDarkMode: false
        )

        XCTAssertNotEqual(initialKey, updatedKey)
    }

    func testMakeLoadKeyIncludesDarkMode() {
        let context = testStack.viewContext
        let message = MessageBuilder()
            .withId("message-id")
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Sender")
            .build(in: context)

        let row = ChatMessageRowModelMapper.map(message)
        let lightKey = EmailContentSection.makeLoadKey(for: row, isDarkMode: false)
        let darkKey = EmailContentSection.makeLoadKey(for: row, isDarkMode: true)

        XCTAssertNotEqual(lightKey, darkKey)
    }

    func testShouldUseTransactionalPreviewCard_forwardedMessage_returnsFalse() {
        XCTAssertFalse(EmailContentSection.shouldUseTransactionalPreviewCard(isForwardedEmail: true))
    }

    func testShouldUseTransactionalPreviewCard_regularMessage_returnsTrue() {
        XCTAssertTrue(EmailContentSection.shouldUseTransactionalPreviewCard(isForwardedEmail: false))
    }

    func testNativePreviewCardRoutes_newsletterFlagAttemptsNewsletterWhenClassifierIsConservative() {
        let routes = EmailContentSection.nativePreviewCardRoutes(
            isNewsletter: true,
            isForwardedEmail: false,
            classificationKind: .personToPerson
        )

        XCTAssertEqual(routes, [.newsletter])
    }

    func testNativePreviewCardRoutes_transactionalClassificationPrecedesNewsletterFlag() {
        let routes = EmailContentSection.nativePreviewCardRoutes(
            isNewsletter: true,
            isForwardedEmail: false,
            classificationKind: .transactional
        )

        XCTAssertEqual(routes, [.transactional, .newsletter])
    }

    func testNativePreviewCardRoutes_forwardedNewsletterFlagWithoutClassificationFallsThroughToHTML() {
        let routes = EmailContentSection.nativePreviewCardRoutes(
            isNewsletter: true,
            isForwardedEmail: true,
            classificationKind: .personToPerson
        )

        XCTAssertEqual(routes, [])
    }

    func testNativePreviewCardRoutes_forwardedNewsletterClassificationFallsThroughToHTML() {
        let routes = EmailContentSection.nativePreviewCardRoutes(
            isNewsletter: false,
            isForwardedEmail: true,
            classificationKind: .newsletter
        )

        XCTAssertEqual(routes, [])
    }

    func testNativePreviewCardRoutes_forwardedTransactionalSkipsTransactionalCard() {
        let routes = EmailContentSection.nativePreviewCardRoutes(
            isNewsletter: false,
            isForwardedEmail: true,
            classificationKind: .transactional
        )

        XCTAssertEqual(routes, [])
    }
}
