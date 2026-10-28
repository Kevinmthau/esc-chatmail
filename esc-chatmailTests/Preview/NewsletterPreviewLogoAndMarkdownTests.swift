import XCTest
@testable import esc_chatmail

/// Newsletter preview cards for ESP templates that hide their logo from the
/// `<img>` tag and write their text/plain part as Markdown. Reproduces a real
/// Klaviyo campaign whose card showed the header logo as its hero image and
/// `[label](url)` link syntax as its subtitle and snippet.
final class NewsletterPreviewLogoAndMarkdownTests: XCTestCase {
    private let sut = NewsletterPreviewBuilder()

    // MARK: - The reported email

    /// Before the fix this card showed the header logo (a 1080x150 white strip)
    /// letterboxed over the placeholder gradient, the subtitle
    /// `[Manhattan Vintage ](https://manhattanvintage.com/)` and a snippet of
    /// raw Markdown links.
    ///
    /// Revert-check: the snippet assertion fails without
    /// `NewsletterLineAnalyzer.markdownLinkRegex`'s replacement in
    /// `previewLines`, and the subtitle assertion fails without the builder's
    /// `displayedSubtitle` (it repeats the snippet).
    /// HONEST SCOPE: the hero assertion fails only when both logo signals are
    /// reverted, `EmailPreviewDOMQuery.enclosingLogoContainerName` and
    /// `NewsletterHeroImageSelector.isNamedOnlyForBrand`, since either alone
    /// demotes this logo; each has its own test below.
    func testBuildPreview_klaviyoHeaderLogoEmail_usesFirstContentImageAndLinkLabels() {
        let result = sut.buildPreview(
            canonicalHTML: Self.klaviyoShoppingListHTML,
            bodyText: Self.klaviyoShoppingListPlainText,
            senderName: "Manhattan Vintage",
            senderEmail: "hello@manhattanvintage.com",
            subject: "Your UES Shopping List is here"
        )

        XCTAssertEqual(
            result?.heroImageURL,
            "https://cdn.klaviyomail.com/company/SFVm5h/images/37021e6e-0ff6-461b-9dc5-86d989b0231a.png"
        )
        XCTAssertEqual(result?.heroImageDisplayMode, .fill)
        XCTAssertEqual(result?.title, "Your UES Shopping List is here")
        XCTAssertEqual(result?.snippet, "our upper east side shopping list")
        XCTAssertNil(result?.subtitle)
    }

    // MARK: - Logo containers

    /// Revert-check: dropping `EmailPreviewDOMQuery.enclosingLogoContainerName`
    /// from the descriptor leaves the logo's descriptor as its bare alt.
    func testImageExtractor_klaviyoHeaderLogo_descriptorCarriesLogoContainerClass() {
        let images = EmailPreviewImageExtractor().extractImages(from: Self.klaviyoShoppingListHTML)

        XCTAssertEqual(images.first?.descriptor, "manhattan vintage hlb-logo")
        XCTAssertEqual(images.first?.altText, "Manhattan Vintage")
        XCTAssertEqual(images.dropFirst().first?.descriptor, "our upper east side shopping list")
    }

    /// The brand mark takes its nearest logo-named container; the lead image,
    /// whose only logo-named ancestor also holds the brand mark, takes none.
    ///
    /// Revert-check: without the `imageCountsByAncestor == 1` stop in
    /// `EmailPreviewDOMQuery.enclosingLogoContainerName` the lead image inherits
    /// `header-logo-row`, is rejected as a logo, and the card loses its hero.
    func testBuildPreview_logoContainerSharedWithLeadImage_keepsLeadImageAsHero() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Twelve layers for changeable weather</h1>
            <div class="header-logo-row">
                <span class="brand-logo"><img src="https://cdn.example.com/acme-mark.png" width="600" alt="Acme"></span>
                <img src="https://cdn.example.com/lead-story.jpg" width="600" alt="Lead story">
            </div>
        </body>
        </html>
        """

        let images = EmailPreviewImageExtractor().extractImages(from: html)
        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(images.map(\.descriptor), ["acme brand-logo", "lead story"])
        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/lead-story.jpg")
    }

    // MARK: - Images named for the sender

    /// No class or URL says "logo" here; only the alt, which is the sender's
    /// name, marks the first image as a brand mark.
    ///
    /// Revert-check: removing the `isNamedOnlyForBrand` penalty in
    /// `NewsletterHeroImageSelector.bestCandidate` makes the first image win on
    /// position (50 vs 47).
    func testBuildPreview_leadingImageNamedOnlyForSender_losesToContentImage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Fall layers are here</h1>
            <img src="https://cdn.example.com/acme-top.png" width="600" alt="Acme Outfitters ">
            <img src="https://cdn.example.com/fall-collection.jpg" width="600" alt="Fall collection">
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/fall-collection.jpg")
    }

    /// The sender-name rule is a penalty, not a rejection: an image named for
    /// the sender is still the hero when there is no other candidate.
    ///
    /// Revert-check: turning the `isNamedOnlyForBrand` penalty into a `continue`
    /// leaves this card without a hero.
    /// HONEST SCOPE: removing the penalty entirely also passes; this pins its
    /// size, not its existence.
    func testBuildPreview_onlyImageNamedForSender_staysHero() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>Fall layers are here</h1>
            <img src="https://cdn.example.com/acme-fall.jpg" width="600" alt="Acme Outfitters">
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/acme-fall.jpg")
    }

    // MARK: - Markdown links in plain text

    /// Revert-check: removing the `markdownLinkRegex` replacement in
    /// `NewsletterLineAnalyzer.previewLines` leaves the link and image syntax in
    /// the snippet.
    func testBuildPreview_plainTextMarkdownLinks_keepOnlyTheirLabels() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/fall-collection.jpg" width="600" alt="Fall collection">
        </body>
        </html>
        """
        let bodyText = """
        [Acme Outfitters](https://acme.example.com/)

        Our fall edit is live: [twelve layering pieces](https://acme.example.com/fall?utm_source=email) picked for changeable weather, from waxed jackets to merino.

        ![Fall collection](https://cdn.example.com/fall-collection.jpg)
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        let snippet = result?.snippet ?? ""
        XCTAssertTrue(
            snippet.hasPrefix("Our fall edit is live: twelve layering pieces picked for changeable weather"),
            snippet
        )
        XCTAssertFalse(snippet.contains("]("), snippet)
        XCTAssertFalse(snippet.contains("https://"), snippet)
        XCTAssertFalse(snippet.contains("!"), snippet)
    }

    /// Bracketed text whose parentheses hold no web or mailto target is not a
    /// link and keeps its brackets.
    ///
    /// HONEST SCOPE: passes without the fix too; it guards
    /// `markdownLinkRegex` against matching ordinary bracketed copy.
    func testBuildPreview_bracketedTextWithoutURL_isLeftAlone() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/fall-collection.jpg" width="600" alt="Fall collection">
        </body>
        </html>
        """
        let bodyText = """
        [Members only] Early access to the fall edit opens (Friday at 9am) for everyone on the list.
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(
            result?.snippet,
            "[Members only] Early access to the fall edit opens (Friday at 9am) for everyone on the list."
        )
    }

    // MARK: - Fixtures

    /// A trimmed copy of a real Klaviyo campaign (Manhattan Vintage, Oct 2026).
    /// The header-link-bar logo and the content images keep Klaviyo's exact
    /// wrapper nesting: the logo's own `alt` is just the brand name and the only
    /// "logo" marker is the wrapping `<td class="hlb-logo">`. Every `<img>` has
    /// `width="600"` and no height, so size scoring cannot tell them apart.
    /// Click-tracking tokens are replaced with placeholders.
    private static let klaviyoShoppingListHTML = """
    <!DOCTYPE html><html><head>
    <title>
    </title>
    <style>p { display: block; margin: 13px 0 } .hlb-subblk td { word-break: normal }</style></head>
    <body style="word-spacing:normal;background-color:#f5f5f7;">
    <div style="display:none;font-size:1px;color:#ffffff;line-height:1px;max-height:0px;max-width:0px;opacity:0;overflow:hidden;">
          Get inspired, get your tickets\u{2007}\u{034F} \u{2007}\u{034F} \u{2007}\u{034F} \u{00AD} \u{00AD} \u{00AD}
        </div>
    <div class="root-container" id="bodyTable" style="background-color:#f5f5f7;">
    <div class="root-container-spacing">
    <table align="center" border="0" cellpadding="0" cellspacing="0" class="kl-section" role="presentation" style="width:100%;">
    <tbody><tr><td>
    <div style="margin:0px auto;max-width:600px;">
    <div class="content-padding kl-first">
    <div class="kl-row colstack" style="display:table;table-layout:fixed;width:100%;">
    <div class="kl-column" style="display:table-cell;vertical-align:top;width:100%;">
    <div class="mj-column-per-100 mj-outlook-group-fix component-wrapper hlb-wrapper" style="font-size:0px;text-align:left;direction:ltr;vertical-align:top;width:100%;">
    <table border="0" cellpadding="0" cellspacing="0" role="presentation" style="width:100%;" width="100%">
    <tbody><tr>
    <td class="hlb-block-settings-content" style="background-color:#FFFFFF;vertical-align:top;padding-top:6px;padding-right:20px;padding-bottom:0px;padding-left:20px;">
    <table border="0" cellpadding="0" cellspacing="0" role="presentation" style="" width="100%">
    <tbody><tr>
    <td align="top" class="kl-header-link-bar" style="font-size:0px;padding:0px 0px 0px 0px;word-break:break-word;">
    <table border="0" cellpadding="0" cellspacing="0" style="color:#000000;font-size:13px;line-height:22px;table-layout:auto;width:100%;border:0;" width="100%">
    <tbody><tr>
    <td align="center" class="hlb-logo" style="display:table-cell;width:100%;padding-bottom:0px;">
    <table border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse;border-spacing:0px;">
    <tbody><tr>
    <td style="width:600px;">
    <a style="color:#e11d48; text-decoration:underline" target="_blank" href="https://ctrk.klclick1.com/l/EXAMPLE_0">
    <img alt="Manhattan Vintage " src="https://d3k81ch9hvuctc.cloudfront.net/company/SFVm5h/images/5bfdb1e7-d3a5-4e2d-9806-6baaa1e6a601.png" style="display:block;outline:none;text-decoration:none;height:auto;width:100%;background-color:transparent;" width="600">
    </a>
    </td>
    </tr></tbody>
    </table>
    </td>
    </tr></tbody>
    </table>
    </td>
    </tr></tbody>
    </table>
    </td>
    </tr></tbody>
    </table>
    </div>
    \(klaviyoImageBlock(alt: "our upper east side shopping list", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/37021e6e-0ff6-461b-9dc5-86d989b0231a.png", link: 1))
    \(klaviyoImageBlock(alt: "Our upper east side shopping list", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/996c3982-4948-4f54-beba-0a0e0d329844.png", link: 2))
    \(klaviyoImageBlock(alt: "The inspiration", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/34e66c84-0de9-46ee-810c-2c181234c4f7.png", link: 3))
    \(klaviyoImageBlock(alt: "The inspiration", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/475343e7-763c-4093-8099-f2ffdef95b92.png", link: 4))
    <div class="mj-column-per-100 mj-outlook-group-fix component-wrapper" style="font-size:0px;text-align:left;direction:ltr;vertical-align:top;width:100%;">
    <table border="0" cellpadding="0" cellspacing="0" role="presentation" style="width:100%;" width="100%">
    <tbody><tr>
    <td align="center" style="font-size:0px;padding:0px;word-break:break-word;">
    <p style="padding-bottom:0; border-top:solid 1px #4C1417; font-size:1px; margin:0 auto; width:100%">
    </p>
    </td>
    </tr></tbody>
    </table>
    </div>
    \(klaviyoImageBlock(alt: "Material Matters", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/91358b60-815b-4d66-9d23-241443e261a9.png", link: 5))
    </div>
    </div>
    </div>
    </div>
    </td></tr></tbody>
    </table>
    <table align="center" border="0" cellpadding="0" cellspacing="0" class="kl-section" role="presentation" style="width:100%;">
    <tbody><tr><td>
    <div class="content-padding kl-last">
    <div class="kl-row colstack" style="display:table;table-layout:fixed;width:100%;">
    <div class="kl-column" style="display:table-cell;vertical-align:top;width:100%;">
    <div style="width:100%;text-align:center">
    <div class="" style="display:inline-block;padding-right:10px;">
    <div style="text-align: center;">
    <a style="color:#e11d48; text-decoration:underline" target="_blank" href="https://ctrk.klclick1.com/l/EXAMPLE_6">
    <img alt="tiktok" src="https://cdn.klaviyomail.com/assets/email/buttons/subtleinverse/instagram_96.png" style="width:32px;" width="32">
    </a>
    </div>
    </div>
    <div class="" style="display:inline-block;">
    <div style="text-align: center;">
    <a style="color:#e11d48; text-decoration:underline" target="_blank" href="https://ctrk.klclick1.com/l/EXAMPLE_7">
    <img alt="Tiktok" src="https://cdn.klaviyomail.com/assets/email/buttons/subtleinverse/tiktok_96.png" style="width:32px;" width="32">
    </a>
    </div>
    </div>
    </div>
    <a class="kl-img-link" style="color:#e11d48; text-decoration:underline; display:block" href="https://ctrk.klclick1.com/l/EXAMPLE_8">
    <img alt="Manhattan Vintage" src="https://d3k81ch9hvuctc.cloudfront.net/company/SFVm5h/images/a407b0b5-62f2-4508-bfc4-962fa909b925.png" style="display:block;outline:none;text-decoration:none;height:auto;font-size:13px;width:100%;" title="Manhattan Vintage" width="586">
    </a>
    <div style="font-family:Helvetica, Arial, sans-serif;font-size:12px;font-style:normal;font-weight:400;letter-spacing:0px;line-height:1.3;text-align:center;color:#FFFFFF;"><div><span style="color: rgb(255, 255, 255); font-size: 9px;">No longer want to receive these emails? </span><a rel="noopener noreferrer nofollow" style="color:rgb(255, 255, 255); text-decoration:underline" target="_blank" href="https://ctrk.klclick1.com/l/EXAMPLE_9"><span style="font-style: normal; color: rgb(255, 255, 255); font-family: Helvetica, Arial, sans-serif; font-size: 9px;"><span style="font-weight: 400;">Unsubscribe</span></span></a><span style="color: rgb(255, 255, 255); font-size: 9px;">.<br></span><span style="font-style: normal; letter-spacing: 0px; color: rgb(255, 255, 255); font-family: Helvetica, Arial, sans-serif; font-size: 9px;"><span style="font-weight: 400;">Manhattan Vintage</span></span><span style="color: rgb(255, 255, 255); font-size: 9px;">\u{200B}&nbsp; &nbsp;</span><span style="font-style: normal; letter-spacing: 0px; color: rgb(255, 255, 255); font-family: Helvetica, Arial, sans-serif; font-size: 9px;"><span style="font-weight: 400;">315 Flatbush Avenue #415 Brooklyn, NY 11217</span></span></div></div>
    </div>
    </div>
    </div>
    </td></tr></tbody>
    </table>
    </div>
    </div>
    <img src="https://ctrk.klclick1.com/o/EXAMPLE" alt="" width="1" height="1" border="0" style="height:1px !important;width:1px !important;border-width:0 !important;"/>
    </body></html>
    """

    /// The campaign's text/plain part, quoted-printable decoded: Klaviyo writes
    /// every link, image links included, as `[label](url)`.
    private static let klaviyoShoppingListPlainText = """
    [Manhattan Vintage ](https://manhattanvintage.com/)

    [our upper east side shopping list](https://www.eventbrite.com/e/manhattan-vintage-upper-east-side-november-14-15-2026-tickets-2002968293083?aff=Klaviyo)

    [Our upper east side shopping list](https://www.eventbrite.com/e/manhattan-vintage-upper-east-side-november-14-15-2026-tickets-2002968293083?aff=Klaviyo)

    [The inspiration](https://www.eventbrite.com/e/manhattan-vintage-upper-east-side-november-14-15-2026-tickets-2002968293083?aff=Klaviyo)

    [The inspiration](https://www.eventbrite.com/e/manhattan-vintage-upper-east-side-november-14-15-2026-tickets-2002968293083?aff=Klaviyo)

    [Material Matters](https://www.eventbrite.com/e/material-matters-november-7-8-tickets-1999290791577?aff=Emails)

    [tiktok](https://www.instagram.com/thevintageshow/)
    [Tiktok](https://www.tiktok.com/tag/manhattanvintageshow)

    [Manhattan Vintage](https://manhattanvintage.com/)

    No longer want to receive these emails? [Unsubscribe](https://manage.kmail-lists.com/subscriptions/unsubscribe?a=EXAMPLE).
    Manhattan Vintage\u{200B}\u{00A0} \u{00A0}315 Flatbush Avenue #415 Brooklyn, NY 11217
    """

    /// One Klaviyo image block, with the real template's wrapper nesting.
    private static func klaviyoImageBlock(alt: String, source: String, link: Int) -> String {
        """
        <div class="mj-column-per-100 mj-outlook-group-fix component-wrapper" style="font-size:0px;text-align:left;direction:ltr;vertical-align:top;width:100%;">
        <table border="0" cellpadding="0" cellspacing="0" role="presentation" style="width:100%;" width="100%">
        <tbody><tr>
        <td class="" style="vertical-align:top;padding-top:0px;padding-right:0px;padding-bottom:0px;padding-left:0px;">
        <table border="0" cellpadding="0" cellspacing="0" role="presentation" style="" width="100%">
        <tbody><tr>
        <td align="center" class="kl-image" style="font-size:0px;word-break:break-word;">
        <table border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse;border-spacing:0px;">
        <tbody><tr>
        <td class="kl-img-base-auto-width" style="border:0;padding:0px 0px 0px 0px;width:600px;" valign="top">
        <a class="kl-img-link" style="color:#e11d48; text-decoration:underline; display:block" href="https://ctrk.klclick1.com/l/EXAMPLE_\(link)">
        <img alt="\(alt)" src="\(source)" style="display:block;outline:none;text-decoration:none;height:auto;font-size:13px;width:100%;" title="\(alt)" width="600">
        </a>
        </td>
        </tr></tbody>
        </table>
        </td>
        </tr></tbody>
        </table>
        </td>
        </tr></tbody>
        </table>
        </div>
        """
    }
}
