import CoreGraphics
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

    func testBuildPreview_keepsUnhintedModeratelyWideHeroAheadOfLaterSquareImage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Campus dispatch</h1>
            <p>The first photo is the intended lead image for this issue.</p>
            <img src="https://cdn.example.com/lead-photo.jpg" width="612" height="240" alt="Campus view">
            <img src="https://cdn.example.com/secondary-photo.jpg" width="240" height="240" alt="Student portrait">
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Campus dispatch"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/lead-photo.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
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

    func testBuildPreview_doesNotPromoteDecimalWidthImageOverWideHeaderHero() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://mcusercontent.com/list/images/tulane-mark.png" width="238.68" height="auto" class="mceImage">
            <img src="https://mcusercontent.com/list/images/tulane-header.jpg" width="612" height="240" alt="Tulane University">
            <h1>TIME TO SUBMIT YOUR PHOTO &amp; INFO FOR THE 2026 TULANE NEW STUDENT BOOK</h1>
            <p>Dear Tulane Parent, congratulations on your student being part of the Class of 2030.</p>
        </body>
        </html>
        """
        let images = EmailPreviewImageExtractor().extractImages(from: html)

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Tulane University New Student Book",
            senderEmail: "manager@maincampuspublications.com",
            subject: "Tulane Parents -- Tulane New Student Book Items Needed"
        )

        XCTAssertEqual(images.first?.width, 239)
        XCTAssertNil(images.first?.height)
        XCTAssertEqual(result?.heroImageURL, "https://mcusercontent.com/list/images/tulane-header.jpg")
        XCTAssertEqual(result?.heroImageDisplayMode, .fit)
    }

    func testHeroDisplayModeResolvedKeepsModeratelyWideDecodedImagesFilled() {
        let resolvedMode = NewsletterPreviewHeroImageDisplayMode.resolved(
            preferred: .fill,
            imageSize: CGSize(width: 612, height: 240)
        )

        XCTAssertEqual(resolvedMode, .fill)
    }

    func testImageExtractorIgnoresDimensionAboveIntMax() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/hero.jpg" width="9223372036854775808" height="240" alt="Hero image">
        </body>
        </html>
        """

        let images = EmailPreviewImageExtractor().extractImages(from: html)

        XCTAssertNil(images.first?.width)
        XCTAssertEqual(images.first?.height, 240)
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

    func testBuildPreview_skipsTrackingURLSnippetAndListItemSubtitle() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="http://cdn.mcauto-images-production.sendgrid.net/list/wimbledon-hero.gif" width="1080" height="1080" alt="Wimbledon hero">
            <table>
                <tr><td class="header-1">Centre Court.</td></tr>
                <tr><td class="header-1-subdued">New London Spots.</td></tr>
            </table>
            <p>Atlas Concierge can secure the most exclusive access to the All England Lawn Tennis Club before the first serve.</p>
        </body>
        </html>
        """

        let invisiblePreviewPadding = String(repeating: "\u{034F}\u{200C}\u{00A0}", count: 8)
        let bodyText = """
        \(invisiblePreviewPadding)
        ( https://www.atlascard.com?utm_campaign=website&utm_medium=email&utm_source=sendgrid.com ) Centre Court. New London Spots. Hi Kevin Michael.
        * Priority room upgrade
        * Daily breakfast
        Courtside access for the Grand Slam
        Atlas Concierge can secure the most exclusive access to the All England Lawn Tennis Club before the first serve.
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            cleanedSnippet: "( https://www.atlascard.com?utm_campaign=website&utm_medium=email&utm_source=sendgrid.com ) Centre Court. New London Spots.",
            senderName: "Atlas",
            senderEmail: "hello@atlascard.com",
            subject: "May 2026 | Wimbledon, London Hot Spots, Concierge for The Championships"
        )

        XCTAssertEqual(
            result?.heroImageURL,
            "https://cdn.mcauto-images-production.sendgrid.net/list/wimbledon-hero.gif"
        )
        XCTAssertEqual(result?.subtitle, "Courtside access for the Grand Slam")
        XCTAssertTrue(result?.snippet.contains("Atlas Concierge can secure") == true)
        XCTAssertFalse(result?.snippet.contains("atlascard.com") == true)
        XCTAssertFalse(result?.subtitle?.contains("Priority room upgrade") == true)
    }

    func testBuildPreview_stripsLeadingTrackingURLFromCleanedSnippet() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Design Weekly</h1>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "( https://click.example.com/open?utm_campaign=weekly ) New gallery openings, studio visits, and handmade pieces are highlighted in this week's design edit.",
            senderName: "Design Weekly",
            senderEmail: "dispatch@example.com",
            subject: "Design Weekly"
        )

        XCTAssertTrue(result?.snippet.hasPrefix("New gallery openings") == true)
        XCTAssertFalse(result?.snippet.contains("click.example.com") == true)
    }

    func testBuildPreview_preservesOnlyTeaserLineAfterLeadingTrackingURL() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Travel Notes</h1>
        </body>
        </html>
        """

        let bodyText = """
        ( https://track.example.com/click/abc?utm_campaign=newsletter ) A new set of coastal retreats is opening this summer, with early booking windows and design notes for travelers.
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "Travel Notes",
            senderEmail: "dispatch@example.com",
            subject: "Travel Notes"
        )

        XCTAssertTrue(result?.snippet.hasPrefix("A new set of coastal retreats") == true)
        XCTAssertFalse(result?.snippet.contains("track.example.com") == true)
    }

    func testBuildPreview_preservesOnlyTeaserLineAfterLeadingUTMURL() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Travel Notes</h1>
        </body>
        </html>
        """

        let bodyText = """
        ( https://www.atlascard.com?utm_campaign=website&utm_medium=email&utm_source=sendgrid.com ) Centre Court. New London Spots. Hi Kevin Michael.
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "Atlas",
            senderEmail: "hello@atlascard.com",
            subject: "Travel Notes"
        )

        XCTAssertTrue(result?.snippet.hasPrefix("Centre Court. New London Spots.") == true)
        XCTAssertFalse(result?.snippet.contains("atlascard.com") == true)
    }

    func testBuildPreview_keepsTrackingURLTeaserWhenLaterLineIsShortCTA() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Style Notes</h1>
        </body>
        </html>
        """

        let bodyText = """
        ( https://track.example.com/click/abc?utm_campaign=newsletter ) Linen layers, beach-ready accessories, and early summer staples are now available for the warmer weekends ahead.
        Read more
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "Style Notes",
            senderEmail: "dispatch@example.com",
            subject: "Style Notes"
        )

        XCTAssertTrue(result?.snippet.hasPrefix("Linen layers") == true)
        XCTAssertFalse(result?.snippet.contains("track.example.com") == true)
        XCTAssertFalse(result?.snippet == "example.com")
    }

    func testBuildPreview_rejectsNonTrackingURLPreferredSnippetNavigationCopy() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Weekly Edit</h1>
            <p>A sharper edit of office staples, weekend layers, and practical accessories just landed.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com Women Men Kids Sale Dresses New Arrivals",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )

        XCTAssertTrue(result?.snippet.contains("office staples") == true)
        XCTAssertFalse(result?.snippet.contains("Women Men Kids Sale") == true)
    }

    func testBuildPreview_rejectsNonTrackingURLPlainTextNavigationCopy() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Weekly Edit</h1>
            <p>A sharper edit of office staples, weekend layers, and practical accessories just landed.</p>
        </body>
        </html>
        """

        let bodyText = """
        https://brand.example.com Women Men Kids Sale Dresses New Arrivals
        New sale styles are live
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )

        XCTAssertTrue(result?.snippet.contains("office staples") == true)
        XCTAssertFalse(result?.snippet.contains("Women Men Kids Sale") == true)
    }

    func testBuildPreview_rejectsUTMURLNavigationCopy() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Weekly Edit</h1>
            <p>A sharper edit of office staples, weekend layers, and practical accessories just landed.</p>
        </body>
        </html>
        """

        let preferredResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com?utm_source=email Women Men Kids Sale Dresses New Arrivals",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )

        let bodyResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: "https://brand.example.com?utm_source=email Women Men Kids Sale Dresses New Arrivals",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )
        let shortNavigationResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com?utm_source=email Shop the new arrivals now",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )
        let shortNavigationWithConnectorsResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com?utm_source=email Shop the new arrivals for summer",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )
        let shortNavigationWithConnectorsBodyResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: "https://brand.example.com?utm_source=email Shop the new arrivals for summer",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )
        let ctaResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com?utm_source=email Explore all sale styles now",
            senderName: "Weekly Edit",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Edit"
        )

        XCTAssertTrue(preferredResult?.snippet.contains("office staples") == true)
        XCTAssertFalse(preferredResult?.snippet.contains("Women Men Kids Sale") == true)
        XCTAssertTrue(bodyResult?.snippet.contains("office staples") == true)
        XCTAssertFalse(bodyResult?.snippet.contains("Women Men Kids Sale") == true)
        XCTAssertTrue(shortNavigationResult?.snippet.contains("office staples") == true)
        XCTAssertFalse(shortNavigationResult?.snippet.contains("Shop the new arrivals") == true)
        XCTAssertTrue(shortNavigationWithConnectorsResult?.snippet.contains("office staples") == true)
        XCTAssertFalse(shortNavigationWithConnectorsResult?.snippet.contains("Shop the new arrivals") == true)
        XCTAssertTrue(shortNavigationWithConnectorsBodyResult?.snippet.contains("office staples") == true)
        XCTAssertFalse(shortNavigationWithConnectorsBodyResult?.snippet.contains("Shop the new arrivals") == true)
        XCTAssertTrue(ctaResult?.snippet.contains("office staples") == true)
        XCTAssertFalse(ctaResult?.snippet.contains("Explore all sale styles") == true)
    }

    func testBuildPreview_preservesShortUTMTeaserHeadline() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Style Notes</h1>
        </body>
        </html>
        """
        let teaser = "Spring styles just landed"

        let preferredResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com?utm_source=email \(teaser)",
            senderName: "Style Notes",
            senderEmail: "dispatch@example.com",
            subject: "Style Notes"
        )

        let bodyResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: "https://brand.example.com?utm_source=email \(teaser)",
            senderName: "Style Notes",
            senderEmail: "dispatch@example.com",
            subject: "Style Notes"
        )
        let retailHeadlineResult = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            cleanedSnippet: "https://brand.example.com?utm_source=email New shoes and dresses are here",
            senderName: "Style Notes",
            senderEmail: "dispatch@example.com",
            subject: "Style Notes"
        )

        XCTAssertEqual(preferredResult?.snippet, teaser)
        XCTAssertEqual(bodyResult?.snippet, teaser)
        XCTAssertEqual(retailHeadlineResult?.snippet, "New shoes and dresses are here")
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

    func testBuildPreview_usesDOMSummaryForUnquotedPreheader() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Weekly Dispatch</title></head>
        <body>
            <div class=preheader>Studio visits and new gallery openings</div>
            <p>A sharper edit of exhibitions, artist talks, and editions worth tracking this week.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Design Weekly",
            senderEmail: "dispatch@example.com",
            subject: "Weekly Dispatch"
        )

        XCTAssertEqual(result?.title, "Studio visits and new gallery openings")
        XCTAssertTrue(result?.snippet.contains("exhibitions") == true)
    }

    func testBuildPreviewFromSourceUsesSnapshotSummaryInsteadOfReparsingHTMLTitle() {
        let source = EmailPreviewSource(
            messageId: "newsletter-source-snapshot",
            sourceSignature: "sha256:snapshot",
            canonicalHTML: """
            <!DOCTYPE html>
            <html>
            <body>
                <h1>HTML title that should not win</h1>
                <p>HTML text that should not be reparsed by the builder.</p>
            </body>
            </html>
            """,
            plainText: nil,
            extractedText: """
            Snapshot newsletter title
            A durable preview summary should come from the source snapshot once extraction has already run.
            """,
            extractedImages: [],
            htmlSummary: EmailPreviewHTMLSummary(
                h1Text: "Snapshot newsletter title",
                h2Text: nil,
                titleText: nil,
                preheaderText: nil,
                actionLinkTexts: []
            ),
            classification: EmailPreviewClassification(
                kind: .newsletter,
                newsletterScore: 70,
                transactionalScore: 0,
                signals: [.unsubscribeFooter]
            )
        )

        let result = sut.buildPreview(
            source: source,
            senderName: "Example Dispatch",
            senderEmail: "news@example.com",
            subject: nil
        )

        XCTAssertEqual(result?.title, "Snapshot newsletter title")
        XCTAssertTrue(result?.snippet.contains("durable preview summary") == true)
        XCTAssertFalse(result?.title.contains("HTML title") == true)
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
            isDarkMode: false,
            htmlSourceSignature: "sha256:test-source"
        )

        message.cleanedSnippet = "Updated cleaned snippet"
        let updatedKey = EmailContentSection.makeLoadKey(
            for: ChatMessageRowModelMapper.map(message),
            isDarkMode: false,
            htmlSourceSignature: "sha256:test-source"
        )

        XCTAssertNotEqual(initialKey, updatedKey)
    }

    func testMakeLoadKeyIncludesSenderName() {
        let context = testStack.viewContext
        let message = MessageBuilder()
            .withId("message-id")
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Original Sender")
            .build(in: context)

        let initialKey = EmailContentSection.makeLoadKey(
            for: ChatMessageRowModelMapper.map(message),
            isDarkMode: false,
            htmlSourceSignature: "sha256:test-source"
        )

        message.senderName = "Updated Sender"
        let updatedKey = EmailContentSection.makeLoadKey(
            for: ChatMessageRowModelMapper.map(message),
            isDarkMode: false,
            htmlSourceSignature: "sha256:test-source"
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
        let lightKey = EmailContentSection.makeLoadKey(
            for: row,
            isDarkMode: false,
            htmlSourceSignature: "sha256:test-source"
        )
        let darkKey = EmailContentSection.makeLoadKey(
            for: row,
            isDarkMode: true,
            htmlSourceSignature: "sha256:test-source"
        )

        XCTAssertNotEqual(lightKey, darkKey)
    }

    func testPreviewHTMLCacheKeyIncludesSourceSignatureAndPreviewMode() {
        let firstSourceKey = EmailContentSection.makePreviewHTMLCacheKey(
            messageId: "message-id",
            sourceSignature: "sha256:first",
            isDarkMode: false,
            cleanupMode: .none
        )
        let secondSourceKey = EmailContentSection.makePreviewHTMLCacheKey(
            messageId: "message-id",
            sourceSignature: "sha256:second",
            isDarkMode: false,
            cleanupMode: .none
        )
        let darkModeKey = EmailContentSection.makePreviewHTMLCacheKey(
            messageId: "message-id",
            sourceSignature: "sha256:first",
            isDarkMode: true,
            cleanupMode: .none
        )
        let cleanupModeKey = EmailContentSection.makePreviewHTMLCacheKey(
            messageId: "message-id",
            sourceSignature: "sha256:first",
            isDarkMode: false,
            cleanupMode: .quotedOnly
        )

        XCTAssertNotEqual(firstSourceKey, secondSourceKey)
        XCTAssertNotEqual(firstSourceKey, darkModeKey)
        XCTAssertNotEqual(firstSourceKey, cleanupModeKey)
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

    func testRemoteImageFallbackNotificationBuildsOriginalWarmRequestForMatchingMessage() async throws {
        let row = makeRemoteImageWarmRow(id: "warm-message")
        let notification = remoteImageFallbackWarmNotification(messageId: "warm-message")
        let expectedRequest = OriginalEmailWarmRequest(
            messageId: "warm-message",
            bodyStorageURI: "file:///tmp/warm-message.html",
            bodyText: "Warm body",
            senderEmail: "warm@example.com",
            subject: "Warm subject"
        )

        guard let request = EmailContentSection.remoteImageFallbackOriginalWarmRequest(
            for: row,
            notification: notification
        ) else {
            return XCTFail("Expected matching notification to produce an original-email warm request")
        }

        let warmer = RecordingOriginalEmailSourceWarmer()
        let warmTask = EmailContentSection.replacingRemoteImageFallbackOriginalWarmTask(
            nil,
            request: request,
            warmer: warmer
        )
        try await waitForRequestCount(1, in: warmer)

        XCTAssertEqual(request, expectedRequest)
        let recordedRequests = await warmer.recordedRequests()
        XCTAssertEqual(recordedRequests, [expectedRequest])

        warmTask.cancel()
        await warmer.releaseAll()
        await warmTask.value
    }

    func testRemoteImageFallbackNotificationIgnoresNonMatchingMessage() {
        let row = makeRemoteImageWarmRow(id: "warm-message")
        let notification = remoteImageFallbackWarmNotification(messageId: "other-message")

        let request = EmailContentSection.remoteImageFallbackOriginalWarmRequest(
            for: row,
            notification: notification
        )

        XCTAssertNil(request)
    }

    func testRemoteImageFallbackOriginalWarmTaskReplacesStaleWork() async throws {
        let request = OriginalEmailWarmRequest(
            messageId: "warm-message",
            bodyStorageURI: "file:///tmp/warm-message.html",
            bodyText: "Warm body",
            senderEmail: "warm@example.com",
            subject: "Warm subject"
        )
        let warmer = RecordingOriginalEmailSourceWarmer()

        var warmTask: Task<Void, Never>? = EmailContentSection.replacingRemoteImageFallbackOriginalWarmTask(
            nil,
            request: request,
            warmer: warmer
        )
        try await waitForRequestCount(1, in: warmer)

        warmTask = EmailContentSection.replacingRemoteImageFallbackOriginalWarmTask(
            warmTask,
            request: request,
            warmer: warmer
        )
        try await waitForRequestCount(2, in: warmer)
        try await waitForCancellationCount(1, in: warmer)

        warmTask?.cancel()
        await warmer.releaseAll()
        if let warmTask {
            await warmTask.value
        }
    }

    private func makeRemoteImageWarmRow(id: String) -> ChatMessageRowModel {
        let message = MessageBuilder()
            .withId(id)
            .withSubject("Warm subject")
            .withSender(email: "warm@example.com", name: "Warm Sender")
            .withBody("Warm body")
            .build(in: testStack.viewContext)

        message.bodyStorageURI = "file:///tmp/\(id).html"
        message.cleanedSnippet = "Warm cleaned snippet"

        return ChatMessageRowModelMapper.map(message)
    }

    private func remoteImageFallbackWarmNotification(messageId: String) -> Notification {
        Notification(
            name: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification,
            userInfo: [
                HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey: messageId
            ]
        )
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        in warmer: RecordingOriginalEmailSourceWarmer,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await warmer.requestCount() < expectedCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let requestCount = await warmer.requestCount()
        XCTAssertEqual(requestCount, expectedCount, file: file, line: line)
    }

    private func waitForCancellationCount(
        _ expectedCount: Int,
        in warmer: RecordingOriginalEmailSourceWarmer,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await warmer.cancellationCount() < expectedCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let cancellationCount = await warmer.cancellationCount()
        XCTAssertEqual(cancellationCount, expectedCount, file: file, line: line)
    }
}

private actor RecordingOriginalEmailSourceWarmer: OriginalEmailSourceWarming {
    private var requests: [OriginalEmailWarmRequest] = []
    private var cancellations = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func warmOriginalEmailSource(request: OriginalEmailWarmRequest) async {
        requests.append(request)

        await withTaskCancellationHandler {
            await waitUntilReleased()
        } onCancel: {
            Task {
                await self.recordCancellation()
            }
        }
    }

    func recordedRequests() -> [OriginalEmailWarmRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }

    func cancellationCount() -> Int {
        cancellations
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func recordCancellation() {
        cancellations += 1
    }

    private func waitUntilReleased() async {
        guard !isReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }
}
