import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Incoming forwarded mail falls back to the full preview card when no
    /// structured forward summary is available.
    /// Newsletter messages can still use HTML preview cards.
    /// Rich HTML previews are conservative in one-to-one *reply threads* to avoid
    /// treating person-to-person replies like newsletters, but should still show
    /// for genuinely rich transactional/marketing HTML.
    static func shouldShowHTMLPreview(_ input: MessageDisplayInput) -> Bool {
        let hasHTMLSource = input.hasHTMLSource
        let isForwardedEmail = input.isForwardedEmail
        let isNewsletter = input.isNewsletter
        let hasRichHTMLContent = input.hasRichHTMLContent
        let isFromMe = input.isFromMe
        let isOneToOneConversation = input.isOneToOneConversation
        let subject = input.subject
        let senderEmail = input.senderEmail
        let isLikelyCalendarInvite = input.isLikelyCalendarInvite
        let trustedTransactionalSender = isTrustedTransactionalSender(senderEmail)
        // Allow newsletter and rich-content preview routing even if the local HTML file/URI metadata is missing.
        // The preview loader can still recover embedded/recoverable HTML on demand.
        let allowNewsletterRecoveryPreview = isNewsletter && !isForwardedEmail
        guard hasHTMLSource || trustedTransactionalSender || hasRichHTMLContent || allowNewsletterRecoveryPreview else {
            return false
        }

        if isForwardedEmail {
            return !isFromMe
        }

        // Trusted transactional system senders should render as preview cards even when
        // HTML metadata/rich-content classification is conservative.
        if trustedTransactionalSender && !isFromMe {
            return true
        }

        let normalizedSubject = subject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isReplySubject = normalizedSubject.hasPrefix("re:")
        let allowsOneToOneReplyPreview =
            isOneToOneConversation &&
            shouldAllowRichReplyPreview(senderEmail: senderEmail, hasRichHTMLContent: hasRichHTMLContent)

        // Keep one-to-one replies in chat bubbles, even if upstream heuristics are noisy.
        if isOneToOneConversation {
            if isFromMe {
                return false
            }

            if isReplySubject && !allowsOneToOneReplyPreview {
                return false
            }
        }

        // Keep personal reply chains in group threads as bubbles unless we have
        // strong newsletter classification.
        if isReplySubject && !isNewsletter && !allowsOneToOneReplyPreview {
            return false
        }

        if isNewsletter {
            return true
        }

        if isLikelyCalendarInvite {
            return true
        }

        // Transactional/marketing HTML can be genuinely rich even in one-to-one conversations.
        // Trust `hasRichHTMLContent` to filter out signature cruft.
        return hasRichHTMLContent
    }

    /// The rich-content verdict a bubble routes on, and whether a load can still change it.
    struct ResolvedRichVerdict: Equatable {
        let hasRichHTMLContent: Bool
        /// False only while the row is waiting on a load to learn its verdict.
        let isKnown: Bool
    }

    /// Resolves the verdict for a bubble's `MessageDisplayInput`: the load's once it has
    /// published, else the verdict stored on the row, else unknown (routed as not rich,
    /// which is all the view had before verdicts were stored).
    ///
    /// The load stays authoritative once it has published. It evaluates the same rule the
    /// stored verdict was stamped with (`RichContentVerdictResolver`) over the row's current
    /// state, so the two differ only when the stored one is stale, and the load then has it
    /// re-stamped (`MessageBubbleLoader.loadContent`).
    ///
    /// - Parameter knownStoredVerdict: `ChatMessageRowModel.knownRichContentVerdict`, already
    ///   nil for rows whose load does not publish the stored rule's answer (own, forwarded,
    ///   and blank-preview rows), for rows never stamped under the current epoch, and for
    ///   rows whose stored text may carry a shared-document link.
    ///
    /// The value and its known-ness come from this one function on purpose. Built separately
    /// (a flag from the row, a value from the view model) the flag could say "known" while
    /// the value was still the view model's default false, and the bubble would render text
    /// and then swap to a card.
    static func resolvedRichVerdict(
        hasLoadedContent: Bool,
        loadedHasRichHTMLContent: Bool,
        knownStoredVerdict: Bool?
    ) -> ResolvedRichVerdict {
        if hasLoadedContent {
            return ResolvedRichVerdict(hasRichHTMLContent: loadedHasRichHTMLContent, isKnown: true)
        }
        if let knownStoredVerdict {
            return ResolvedRichVerdict(hasRichHTMLContent: knownStoredVerdict, isKnown: true)
        }
        return ResolvedRichVerdict(hasRichHTMLContent: false, isKnown: false)
    }

    /// Whether some outcome of the bubble's async content load routes this row to the HTML
    /// preview card.
    ///
    /// The rich-content verdict (`hasRichHTMLContent`) is the routing input a load decides.
    /// With `richVerdictIsKnown` false it is unknown: `input` carries false, the load may
    /// publish either value, and this is `shouldShowHTMLPreview` for either. Both are tried
    /// rather than only `true`, so the answer does not assume a rich verdict can only add
    /// cards. With `richVerdictIsKnown` true, `input` already carries the verdict the load
    /// will publish (`resolvedRichVerdict`), so only that one is asked.
    ///
    /// `hasHTMLSource` also reaches the routing from the view model, but needs no enumerating.
    /// It appears only in the routing's opening guard, and a load only ever upgrades it
    /// (`MessageBubbleHTMLAnalysisBuilder`: hint, or canonical HTML found). The placeholder
    /// decision asks only once it is already true (the guard in `showsTextLoadingPlaceholder`),
    /// so every outcome carries the value asked about. Asked about a row whose hint is still
    /// false, the upgrade is covered only through the rich verdict, which passes the guard on
    /// its own: that one case does assume the routing past the guard cards a rich row wherever
    /// it cards a non-rich one, pinned by `testLoadCanRouteToHTMLPreview_boundsEveryLoadOutcome`.
    /// With a known verdict even that cover is gone: a known not-rich row whose hint is still
    /// false answers false although an upgraded hint could card it (a calendar invite), so
    /// the known form bounds the load's outcomes only once the hint is true, which is the
    /// only place the placeholder decision asks it.
    /// A routing input a load can change that is added later must be enumerated here too.
    static func loadCanRouteToHTMLPreview(
        _ input: MessageDisplayInput,
        richVerdictIsKnown: Bool
    ) -> Bool {
        let verdicts = richVerdictIsKnown ? [input.hasRichHTMLContent] : [false, true]
        return verdicts.contains { verdict in
            shouldShowHTMLPreview(input.withRichHTMLContent(verdict))
        }
    }

    /// Whether a bubble routed to text (not the HTML preview card) shows the "Loading..." pill
    /// instead of its text while the async content load is still running.
    ///
    /// - Parameters:
    ///   - routing: the same `MessageDisplayInput` the bubble routed on
    ///     (`MessageBubble.displayInput`), so this decision and the routing cannot be handed
    ///     different rows.
    ///   - richVerdictIsKnown: whether `routing.hasRichHTMLContent` is a verdict the load
    ///     will not change (`resolvedRichVerdict`), from the same resolution that built
    ///     `routing`.
    ///
    /// Forwarded rows keep the pill until the load publishes, own or incoming, whatever they
    /// store and with or without an HTML source: the first return, ahead of the HTML-source
    /// guard. The load decides their rendering: usually the structured forward summary it parses
    /// (`MessageBubbleLoader.forwardedDisplayContent`), which is not the stored text, and for an
    /// incoming forward without one, the preview card (`MessageBubble.showHTMLPreview` holds a
    /// forward off the card until the load has published). This stays an explicit return rather
    /// than a question for `loadCanRouteToHTMLPreview`: the summary is not a routing outcome,
    /// the routing never cards an own forward, and the probe is asked only past the HTML-source
    /// guard.
    ///
    /// Incoming HTML with no stored `chatPreviewText` keeps the pill: until content detection
    /// finishes, the only text on hand is raw/partial HTML-derived text that the load may replace
    /// or route to a preview card.
    ///
    /// Incoming rows with a stored `chatPreviewText` render it at once exactly when no outcome of
    /// the load can route them to a preview card (`loadCanRouteToHTMLPreview`). For those rows
    /// the stored preview is the row's text: the loader publishes it verbatim as
    /// `fullTextContent` and `resolvedVisibleText` prefers it anyway. The pill bought nothing
    /// there and cost a pill → bubble swap on every fresh mount: the swap grows the transcript,
    /// which below iOS 18 restarts the hidden initial-anchor pass in `ChatMessagesCoordinator`
    /// (its retry budget resets on growth) and so holds the reveal until every visible load has
    /// settled, and on iOS 18 and later, where the hidden pass pins the content end
    /// (`ChatTranscriptScrollAnchorPolicy`), is seen as a pill popping into a bubble whenever
    /// the load outlasts the reveal. With an unknown verdict and today's routing these are the
    /// reply-subject rows the routing has not already carded, flagged newsletter or calendar
    /// invite or not. With a known verdict they are every row the routing has not carded: a
    /// known rich row that routes to a card never reaches this decision (the bubble shows the
    /// card), and any other known row ends as a text bubble.
    ///
    /// One thing the load still adds to such a row is its shared-document links
    /// (`MessageBubbleLoader.extractSharedDocumentLinks`): the bubble strips their URLs from
    /// the text and appends a card for each once they publish. Rows that have always rendered
    /// before their load (replies, own rows) have always shown that change. So that a stored
    /// verdict does not spread it to every incoming row, a row whose stored text mentions a
    /// host such a link can have is not reported as known
    /// (`ChatMessageRowModelMapper.knownRichContentVerdict`) and keeps the pill.
    ///
    /// A row the load can still route to a card keeps the pill, whatever text it stores. That
    /// takes an unknown verdict: a row never stamped under the current verdict epoch (the
    /// launch backfill has not reached it, or its HTML could not be read). Its stored text is
    /// not yet known to be the row's final rendering. Rendering it anyway showed the whole
    /// stored preview and then swapped it for a card: visibly, whenever the load outlasted the
    /// reveal or the row mounted while scrolling back. An incomplete load leaves such a row on
    /// the pill: its result is never applied, so `hasLoadedContent` stays false while the hint
    /// published when the load began still stands. A row with a known verdict renders its
    /// stored text or its card through an incomplete load instead.
    ///
    /// Asked of the routing rather than re-listed here, forwarded rows aside (above). A
    /// hand-kept list of newsletter, invite and trusted-sender exclusions was wrong in both
    /// directions. It kept the pill on rows that can only end as text: the routing has already
    /// carded a flagged row unless its subject is a reply, and a reply it has not carded stays
    /// text whatever the verdict (an incoming trusted sender is always carded, so that exclusion
    /// matched nothing the view asks about). And it rendered text on rows a rich verdict routes
    /// to a card.
    ///
    /// Two paths this does not close, both older than the rule. A row with no HTML-source hint
    /// renders its text at once (the guard below) and can still become a card when the load
    /// finds HTML embedded in its body text; applying the rule there would put the pill on every
    /// plain-text message with a new subject. And a fresh mount's first pass runs before the
    /// load has published the row's hint (`MessageBubbleViewModel.htmlAnalysis` starts `.empty`),
    /// so it takes that same path.
    ///
    /// The user's own non-forwarded rows with a stored `chatPreviewText` skip it. Their final
    /// text is already known: the loader publishes the stored preview as `fullTextContent`,
    /// `resolvedVisibleText` prefers it anyway, and rich-content classification is always false
    /// for `isFromMe`, so the row ends as this same text bubble. The pill bought nothing there and
    /// cost a visible text → "Loading..." → text flicker on every reply: sync replaces the
    /// optimistic row with Gmail's echo, a new object ID, so the bubble remounts with a fresh
    /// view model, and the echo (always multipart/alternative) has an HTML source. A multi-line
    /// reply also collapsed to the one-line pill and regrew. Newsletter and calendar-invite rows
    /// are excluded because they can route to a preview card instead.
    ///
    /// Own rows deliberately do not consult `loadCanRouteToHTMLPreview`. It asks the routing
    /// about a rich verdict the loader never returns for an own row with a stored preview
    /// (`MessageBubbleLoader.loadRichContentClassification`), and the routing alone would card
    /// an own row with a new subject in a group conversation on that verdict, so the pill would
    /// come back on rows that render their text today. For the same reason an own row's stored
    /// verdict never reaches the routing: `ChatMessageRowModelMapper.knownRichContentVerdict`
    /// reports it as unknown.
    ///
    /// The same own rows with no stored preview but with displayed attachments skip it too: an
    /// attachments-only reply. Its stored preview is blank because it has no text of its own
    /// (its plain body is at most the quoted original, which chat display strips), so the load
    /// finds no text either and the bubble ends as it renders before the load: the attachments,
    /// plus the row's fallback preview if it has one. The pill bought nothing there either: it
    /// showed "Loading..." under the attachments and then vanished. Since the transcript keeps
    /// one view across Gmail's echo (`ChatMessageDisplayIdentity`), the echo itself refreshes in
    /// place and no longer reaches this branch, but every fresh mount of such a row still did:
    /// reopening the chat, the row re-entering the loaded window, or an echo that landed while
    /// the chat was closed. A legacy own row with text but no stored preview (the backfill fills
    /// those) shows its fallback preview, if any, until the load swaps in its text, instead of
    /// the pill.
    static func showsTextLoadingPlaceholder(
        hasLoadedContent: Bool,
        routing: MessageDisplayInput,
        richVerdictIsKnown: Bool,
        chatPreviewText: String?,
        hasDisplayableAttachments: Bool
    ) -> Bool {
        guard !hasLoadedContent else { return false }
        if routing.isForwardedEmail { return true }
        guard routing.hasHTMLSource else { return false }

        if !routing.isFromMe {
            let rendersStoredIncomingPreview =
                MessagePreviewText.nonEmpty(chatPreviewText) != nil &&
                !loadCanRouteToHTMLPreview(routing, richVerdictIsKnown: richVerdictIsKnown)
            return !rendersStoredIncomingPreview
        }

        let isOwnTextBubble = !routing.isNewsletter && !routing.isLikelyCalendarInvite
        guard isOwnTextBubble else { return true }
        let rendersStoredOwnPreview = MessagePreviewText.nonEmpty(chatPreviewText) != nil
        return !rendersStoredOwnPreview && !hasDisplayableAttachments
    }

    static func isTrustedTransactionalSender(_ senderEmail: String?) -> Bool {
        PreviewTextUtilities.senderDomain(
            senderEmail,
            matchesDomainOrSuffixIn: trustedTransactionalReplyDomainSuffixes
        )
    }

    private static let trustedTransactionalReplyDomainSuffixes: Set<String> = [
        // eBay buyer/seller relay senders
        "members.ebay.com",
        // BILL approval/transactional notifications
        "bill.com",
        // Marketplace relay/system senders
        "amazon.com",
        "etsy.com",
        "mercari.com",
        "offerup.com",
        "poshmark.com"
    ]

    private static func shouldAllowRichReplyPreview(senderEmail: String?, hasRichHTMLContent: Bool) -> Bool {
        guard hasRichHTMLContent,
              isTrustedTransactionalSender(senderEmail) else {
            return false
        }

        return true
    }
}
