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
    /// The card is built with the snippet the app stores for this email, as the
    /// pipeline builds it: the HTML's footer text, "No longer want to receive
    /// these emails? Unsubscribe. …", which is no snippet at all.
    ///
    /// Revert-check: the snippet assertion fails without
    /// `MarkdownLinkLabels.replacingLinks` in `NewsletterLineAnalyzer.previewLines`.
    /// The subtitle assertion fails without the builder's `displayedSubtitle`
    /// (it repeats the snippet).
    /// HONEST SCOPE: the stored footer's lead-in ("No longer want to receive
    /// these emails") becomes the snippet only when both of its cuts are
    /// reverted, the "no longer want to receive these emails" footer pattern
    /// and the question step in `footerCutLocation`; each has its own test.
    /// The hero assertion fails only when both logo signals are
    /// reverted, `EmailPreviewDOMQuery.enclosingLogoContainerName` and
    /// `NewsletterHeroImageSelector.isNamedOnlyForBrand`, since either alone
    /// demotes this logo; each has its own test below.
    func testBuildPreview_klaviyoHeaderLogoEmail_usesFirstContentImageAndLinkLabels() async throws {
        let storedSnippet = try await storedCleanedSnippet(
            html: Self.klaviyoShoppingListHTML,
            plainText: Self.klaviyoShoppingListPlainText
        )
        XCTAssertEqual(storedSnippet?.hasPrefix("No longer want to receive these emails? Unsubscribe."), true, storedSnippet ?? "nil")

        let result = sut.buildPreview(
            canonicalHTML: Self.klaviyoShoppingListHTML,
            bodyText: Self.klaviyoShoppingListPlainText,
            cleanedSnippet: storedSnippet,
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

    /// No stored snippet, so the card's text comes from its lines.
    ///
    /// Revert-check: removing the `MarkdownLinkLabels.replacingLinks` call in
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
    /// `MarkdownLinkLabels`' link pattern against matching ordinary bracketed copy.
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

    /// A linked image (`[![alt](src)](href)`) is a link around an image, and
    /// keeps only the image's alt. No stored snippet, so the card's text comes
    /// from its lines.
    ///
    /// Revert-check: limiting `MarkdownLinkLabels.replacingLinks` to one pass
    /// leaves `[Twelve layers for changeable weather](https://acme.example.com/fall)`,
    /// too long for a subtitle.
    func testBuildPreview_plainTextLinkedImage_keepsOnlyItsAlt() {
        let bodyText = """
        [![Twelve layers for changeable weather](https://cdn.example.com/fall-collection.jpg)](https://acme.example.com/fall)
        Our fall edit is live, with twelve layering pieces picked for changeable weather.
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.subtitle, "Twelve layers for changeable weather")
        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather.")
    }

    /// A link whose target is the unsubscribe URL ends the card's text there,
    /// as it did before links were stripped, though its label names no footer.
    /// No stored snippet, so the card's text comes from its lines.
    ///
    /// Revert-check: dropping the targets from `NewsletterLineAnalyzer.previewLines`'s
    /// footer check lets the scan run past the link (whose line is still
    /// skipped on its target), and the postal address becomes the subtitle.
    func testBuildPreview_plainTextFooterLinkLabelNamingNoFooter_stopsAtTheLink() {
        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: Self.acmeFooterLinkPlainText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertNil(result?.subtitle)
        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather.")
    }

    /// A line linking a social profile is skipped on its target, as it was
    /// before links were stripped, though its label names no network. No
    /// stored snippet, so the card's text comes from its lines.
    ///
    /// Revert-check: dropping the targets from `NewsletterLineAnalyzer.previewLines`'s
    /// `shouldSkipLine` check makes "Watch the fall lookbook reel" the subtitle.
    func testBuildPreview_plainTextSocialLinkLabelNamingNoNetwork_isSkipped() {
        let bodyText = """
        [Watch the fall lookbook reel](https://www.instagram.com/acme/reel/1)
        Our fall edit is live, with twelve layering pieces picked for changeable weather.
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertNil(result?.subtitle)
        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather.")
    }

    // MARK: - Markdown links in the stored snippet

    /// When the HTML shows no text, the app stores the plain-text part as the
    /// snippet, Markdown links and all, and the card prefers it to its lines.
    ///
    /// Revert-check: without `previewSummaryLinkLabels` in the builder's
    /// `normalizedPreviewSummary` the snippet keeps the link syntax.
    func testBuildPreview_storedMarkdownSnippet_keepsOnlyLinkLabels() async throws {
        let bodyText = """
        Our fall edit is live: [twelve layering pieces](https://acme.example.com/fall?utm_source=email) picked for changeable weather, from waxed jackets to merino.
        """
        let storedSnippet = try await storedCleanedSnippet(html: Self.acmeImageOnlyHTML, plainText: bodyText)
        XCTAssertEqual(storedSnippet?.contains("](https://"), true, storedSnippet ?? "nil")

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            cleanedSnippet: storedSnippet,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        // No trailing period: the stored snippet, not the line, supplied it.
        XCTAssertEqual(
            result?.snippet,
            "Our fall edit is live: twelve layering pieces picked for changeable weather, from waxed jackets to merino"
        )
    }

    /// A footer link's target ends the stored snippet at that link, label and
    /// all, as it did before links were stripped.
    ///
    /// Revert-check: without the `trimmingFooterContent` call in
    /// `previewSummaryLinkLabels` the footer link survives and its target
    /// rejects the whole stored snippet, so the card falls back to its line
    /// (trailing period kept); without `outsideLink` on the pattern's offset in
    /// `footerCutLocation` the cut lands inside the long target and the snippet
    /// ends in `[Click here](https://click.acme.example.com/…`.
    func testBuildPreview_storedMarkdownSnippetWithFooterLink_endsBeforeTheLink() async throws {
        let storedSnippet = try await storedCleanedSnippet(
            html: Self.acmeImageOnlyHTML,
            plainText: Self.acmeFooterLinkPlainText
        )
        XCTAssertEqual(storedSnippet?.contains("[Click here](https://"), true, storedSnippet ?? "nil")

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: Self.acmeFooterLinkPlainText,
            cleanedSnippet: storedSnippet,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather")
        XCTAssertNil(result?.subtitle)
    }

    /// The reported campaign, had its HTML shown no text: the stored snippet is
    /// the whole Markdown plain text. It links a social profile, which rejected
    /// it before links were stripped, so the card still takes its text from its
    /// lines rather than from a run of image-link labels.
    ///
    /// Revert-check: dropping the targets from `normalizedPreviewSummary`'s
    /// `shouldSkipLine` check makes the snippet "The inspiration The
    /// inspiration Material Matters tiktok Tiktok Manhattan Vintage".
    func testBuildPreview_storedMarkdownSnippetLinkingSocialProfile_fallsBackToLines() async throws {
        let storedSnippet = try await storedCleanedSnippet(
            html: Self.klaviyoImageOnlyHTML,
            plainText: Self.klaviyoShoppingListPlainText
        )
        XCTAssertEqual(storedSnippet?.hasPrefix("[Manhattan Vintage ](https://manhattanvintage.com/)"), true, storedSnippet ?? "nil")

        let result = sut.buildPreview(
            canonicalHTML: Self.klaviyoImageOnlyHTML,
            bodyText: Self.klaviyoShoppingListPlainText,
            cleanedSnippet: storedSnippet,
            senderName: "Manhattan Vintage",
            senderEmail: "hello@manhattanvintage.com",
            subject: "Your UES Shopping List is here"
        )

        XCTAssertEqual(result?.snippet, "our upper east side shopping list")
        XCTAssertNil(result?.subtitle)
    }

    /// The stored snippet's leading subject is trimmed before its footer is
    /// found, as for a snippet without links, so "privacy policy" in the
    /// subject it repeats does not end it.
    ///
    /// Revert-check: running `previewSummaryLinkLabels`' footer trim before
    /// `trimmingLeadingSummaryText` cuts the snippet to "Changes to our", which
    /// is rejected, and the card falls back to its source domain.
    func testBuildPreview_storedMarkdownSnippetRepeatingFooterWordSubject_keepsItsBody() async throws {
        let bodyText = """
        Changes to our privacy policy. [Read the update](https://acme.example.com/legal) to see what changes for you this month and how we use your data.
        """
        let storedSnippet = try await storedCleanedSnippet(html: Self.acmeImageOnlyHTML, plainText: bodyText)

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            cleanedSnippet: storedSnippet,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Changes to our privacy policy"
        )

        XCTAssertEqual(
            result?.snippet,
            "Read the update to see what changes for you this month and how we use your data"
        )
    }

    /// A content link whose URL looks like markup to the text-noise checks
    /// (`target=` in its query) is still a content link.
    ///
    /// Revert-check: judging the targets with `shouldSkipLine` again, instead of
    /// the builder's `isSkippedLinkTarget`, drops the line and the subtitle.
    func testBuildPreview_plainTextLinkWithMarkupLikeQuery_keepsItsLabel() {
        let bodyText = """
        [Shop the new fall edit](https://acme.example.com/fall?target=new&utm_source=email)
        Our fall edit is live, with twelve layering pieces picked for changeable weather.
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.subtitle, "Shop the new fall edit")
    }

    /// A link whose parentheses a line break splits is still one link.
    ///
    /// Revert-check: without `MarkdownLinkLabels.joiningLinksSplitAcrossLines`
    /// in `NewsletterLineAnalyzer.previewLines` the first half,
    /// `[Twelve layers for changeable weather](`, becomes the subtitle.
    func testBuildPreview_plainTextLinkSplitAcrossLines_keepsOnlyItsLabel() {
        let bodyText = """
        [Twelve layers for changeable weather](
        https://acme.example.com/fall)
        Our fall edit is live, with twelve layering pieces picked for changeable weather.
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.subtitle, "Twelve layers for changeable weather")
    }

    // MARK: - Footer lead-ins

    /// A short question right before the unsubscribe sentence is the footer's
    /// lead-in, whatever its wording. The stored snippet is an HTML footer as
    /// ingest keeps it, on one line (`PlainTextSignatureRemover` already drops a
    /// trailing unsubscribe line from a plain-text part).
    ///
    /// Revert-check: without the question step in the builder's
    /// `footerCutLocation` the snippet ends "…weather. Don't want these emails
    /// anymore".
    func testBuildPreview_storedSnippetFooterQuestion_isCutWithTheFooter() {
        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: nil,
            cleanedSnippet: "Our fall edit is live, with twelve layering pieces picked for changeable weather. Don't want these emails anymore? Unsubscribe from this list.",
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather")
    }

    /// The words of the unsubscribe sentence before "unsubscribe" go with it,
    /// as in the standard "…update your preferences or unsubscribe" footer.
    ///
    /// Revert-check: without the sentence step in the builder's
    /// `footerCutLocation` the snippet ends "…weather. You can update your
    /// preferences or".
    func testBuildPreview_storedSnippetFooterSentenceLeadIn_isCutWithTheFooter() async throws {
        let bodyText = """
        Our fall edit is live, with twelve layering pieces picked for changeable weather.
        You can update your preferences or unsubscribe from this list.
        """
        let storedSnippet = try await storedCleanedSnippet(html: Self.acmeImageOnlyHTML, plainText: bodyText)
        XCTAssertEqual(storedSnippet?.hasSuffix("preferences or unsubscribe from this list."), true, storedSnippet ?? "nil")

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            cleanedSnippet: storedSnippet,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather")
    }

    /// A stored snippet collapsed from lines with no sentence punctuation (an
    /// HTML footer as ingest keeps it, on one line) has no sentence to step
    /// back over, so it is cut at the footer word, as before.
    ///
    /// Revert-check: letting `footerCutLocation` step back to the text's start
    /// when no boundary precedes the footer empties this snippet, and the card
    /// shows its subtitle line, "Twelve new layering pieces", instead.
    func testBuildPreview_storedRunOnSnippet_isCutAtTheFooterWord() {
        let bodyText = """
        Fall edit is live
        Twelve new layering pieces
        Unsubscribe from this list
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            cleanedSnippet: "Fall edit is live Twelve new layering pieces Unsubscribe from this list",
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.snippet, "Fall edit is live Twelve new layering pieces")
    }

    /// The unsubscribe lead-in on a line of its own ends the card's text, as
    /// the unsubscribe line after it would. No stored snippet, so the card's
    /// text comes from its lines.
    ///
    /// Revert-check: without the "no longer want to receive these emails"
    /// footer pattern the lead-in becomes the subtitle.
    func testBuildPreview_plainTextFooterLeadInOnItsOwnLine_endsTheCardText() {
        let bodyText = """
        Our fall edit is live, with twelve layering pieces picked for changeable weather.
        No longer want to receive these emails?
        [Unsubscribe](https://acme.example.com/u/1)
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertNil(result?.subtitle)
        XCTAssertEqual(result?.snippet, "Our fall edit is live, with twelve layering pieces picked for changeable weather.")
    }

    /// "No longer wish to receive" in ordinary copy is not a footer: the lead-in
    /// patterns are anchored on "these emails".
    ///
    /// Revert-check: unanchored "no longer wish to receive" stops the card's
    /// text at the second line.
    func testBuildPreview_plainTextNoLongerWishToReceiveInCopy_isKept() {
        let bodyText = """
        Our fall statement edition is here, with what changed this quarter.
        Customers who no longer wish to receive paper statements can switch to e-statements in the app.
        """

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            senderName: "Acme Bank",
            senderEmail: "hello@acme.example.com",
            subject: "Your fall statement edition"
        )

        XCTAssertEqual(result?.snippet.contains("paper statements"), true, result?.snippet ?? "nil")
    }

    /// The builder decodes a stored snippet's entities once, as it did before
    /// link stripping added a second normalization.
    ///
    /// Revert-check: normalizing `previewSummaryLinkLabels`' result again
    /// decodes "&amp;" to "&".
    func testBuildPreview_storedSnippetEntities_areDecodedOnce() {
        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: nil,
            cleanedSnippet: "Our statement guide: what &amp;amp; means on your bill, and eleven other questions answered.",
            senderName: "Acme Bank",
            senderEmail: "hello@acme.example.com",
            subject: "Your fall statement edition"
        )

        XCTAssertEqual(
            result?.snippet,
            "Our statement guide: what &amp; means on your bill, and eleven other questions answered"
        )
    }

    /// A stray `[` before a stored snippet's footer is prose, not a cut link,
    /// and stays.
    ///
    /// Revert-check: dropping everything from an unclosed `[` to the end of the
    /// cut text, as #339's `removingTrailingPartialLink` did, leaves "Shop now
    /// Save 20%", which is rejected.
    func testBuildPreview_storedMarkdownSnippetWithStrayBracket_keepsTheProse() async throws {
        let bodyText = """
        [Shop now](https://acme.example.com/fall) Save 20% [code FALL at checkout through Sunday. Unsubscribe: https://acme.example.com/u/1
        """
        let storedSnippet = try await storedCleanedSnippet(html: Self.acmeImageOnlyHTML, plainText: bodyText)
        XCTAssertEqual(storedSnippet?.contains("Sunday. Unsubscribe:"), true, storedSnippet ?? "nil")

        let result = sut.buildPreview(
            canonicalHTML: Self.acmeImageOnlyHTML,
            bodyText: bodyText,
            cleanedSnippet: storedSnippet,
            senderName: "Acme Outfitters",
            senderEmail: "hello@acme.example.com",
            subject: "Fall layers"
        )

        XCTAssertEqual(result?.snippet, "Shop now Save 20% [code FALL at checkout through Sunday")
    }

    // MARK: - Helpers

    /// The `cleanedSnippet` the app stores for a message with these parts, from
    /// its production ingest caller (`MessageProcessor.processGmailMessage`), as
    /// `GoldenCorpusReplayTests` pins it. The pipeline always passes it and it
    /// wins over the card's own lines, so a card built without it is not the
    /// card the app shows. The processor gets a fetcher that fails the test, so
    /// these stay off `GmailAPIClient.shared`: every fixture part is inline.
    private func storedCleanedSnippet(html: String?, plainText: String?) async throws -> String? {
        let messageID = "newsletter-markdown-\(UUID().uuidString)"
        let parts = [("text/html", html), ("text/plain", plainText)]
            .enumerated().compactMap { index, item -> MessagePart? in
                guard let content = item.1 else { return nil }
                return MessagePart(
                    partId: "0.\(index)", mimeType: item.0, filename: nil, headers: nil,
                    body: MessageBody(size: content.utf8.count,
                                      data: Data(content.utf8).base64EncodedString(), attachmentId: nil),
                    parts: nil
                )
            }
        let message = GmailMessage(
            id: messageID, threadId: messageID, labelIds: ["INBOX"],
            snippet: nil, historyId: nil, internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0", mimeType: "multipart/alternative", filename: nil,
                headers: [MessageHeader(name: "From", value: "newsletter@example.com"),
                          MessageHeader(name: "To", value: "me@example.com")],
                body: nil, parts: parts
            ), sizeEstimate: nil
        )

        let processor = MessageProcessor(fetchAttachmentData: { messageID, attachmentID in
            XCTFail("Unexpected attachment fetch \(attachmentID) for \(messageID); fixture parts are inline")
            throw URLError(.notConnectedToInternet)
        })
        let processed = try await processor.processGmailMessage(message, myAliases: ["me@example.com"])
        return processed?.cleanedSnippet
    }

    // MARK: - Fixtures

    /// An image-only body: its HTML shows no text, so the app stores the
    /// plain-text part as the snippet.
    private static let acmeImageOnlyHTML = """
    <!DOCTYPE html>
    <html>
    <body>
        <a href="https://acme.example.com/fall"><img src="https://cdn.example.com/fall-collection.jpg" width="600" alt="Fall collection"></a>
    </body>
    </html>
    """

    /// A footer link whose label names no footer; only its target does, deep
    /// in a click-tracking URL, more than a footer lead-in's length past the
    /// start of its sentence.
    private static let acmeFooterLinkPlainText = """
    Our fall edit is live, with twelve layering pieces picked for changeable weather.
    [Click here](https://click.acme.example.com/ls/click?upn=Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0/unsubscribe?u=1) to stop getting these emails.
    Acme Outfitters, 12 Harbor Street, Portland ME 04101
    """

    /// The reported campaign's content images without its footer text, so its
    /// HTML shows no text, as when a campaign's footer is hidden from snippet
    /// extraction, and the app stores the Markdown plain text as the snippet.
    private static let klaviyoImageOnlyHTML = """
    <!DOCTYPE html><html><body>
    \(klaviyoImageBlock(alt: "our upper east side shopping list", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/37021e6e-0ff6-461b-9dc5-86d989b0231a.png", link: 1))
    \(klaviyoImageBlock(alt: "The inspiration", source: "https://cdn.klaviyomail.com/company/SFVm5h/images/34e66c84-0de9-46ee-810c-2c181234c4f7.png", link: 3))
    </body></html>
    """

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
