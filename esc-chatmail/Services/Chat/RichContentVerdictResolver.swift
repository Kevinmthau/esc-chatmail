import Foundation

/// The stored state a message's rich-content verdict is a function of. Nothing else is an
/// input: not `chatPreviewText`, the subject, the newsletter flag, the sender, or attachments.
struct RichContentVerdictInputs: Sendable, Equatable {
    let messageID: String
    let isFromMe: Bool
    let bodyStorageURI: String?
    /// Raw `Message.bodyText`: not trimmed, and nil is distinct from blank (a blank body
    /// still suppresses the snippet below).
    let bodyText: String?
    /// Raw `Message.snippet`, consulted only when `bodyText` is nil.
    let snippet: String?
}

/// The single definition of a message's rich-content verdict:
///
///     !isFromMe && (classifier(candidate HTML) || (hasHTMLSource && bodyText ?? snippet
///                                                  reads like a newsletter's fallback text))
///
/// Every producer of a verdict evaluates it here, over the row's stored state: the bubble
/// loader (`MessageBubbleLoader.loadRichContentClassification`), sync
/// (`MessagePersister.stampRichContentVerdict`), the launch backfill
/// (`RichContentVerdictBackfill`) and the refresher (`RichContentVerdictRefresher`). A stored
/// verdict is only useful if the load then agrees with it, so the writers must not carry a
/// second copy of this rule.
///
/// The loader evaluates it in two steps (`cheapTerms`, then `classifierCandidate`) so it can
/// memoize the one expensive part, the classifier, under the candidate's source signature.
/// The terms outside the classifier are evaluated fresh on every call: memoized together
/// with it they went stale, because the memo's key covers only the candidate.
enum RichContentVerdictResolver {
    /// Where the message's stored HTML comes from.
    enum StoredHTML: Sendable {
        /// Read `<Messages>/<id>.html`, then the file at `bodyStorageURI`, through the handler.
        case readThroughHandler
        /// The string a successful save for this message has just written, so the file need
        /// not be read back. The message then has an HTML source by definition.
        case justSaved(String)
    }

    enum CheapTerms: Equatable {
        /// Decided without looking at any HTML.
        case decided(Bool)
        /// The verdict is the classifier's answer for `classifierCandidate`.
        case classifierDecides
    }

    enum ClassifierCandidate: Equatable {
        case html(String)
        /// The message has no HTML to classify: the classifier term is false.
        case none
        /// A stored HTML file exists but could not be read (an I/O error, or the account
        /// boundary refused the read). Not the same as having no HTML: classifying the next
        /// candidate instead would call a row with rich HTML on disk "not rich".
        case undetermined
    }

    /// The terms that need no HTML. Own rows are never rich. A row with an HTML source whose
    /// plain text reads like a newsletter's "view in browser / unsubscribe" fallback is rich
    /// whatever its HTML classifies as.
    ///
    /// "Has an HTML source" is `bodyStorageURI != nil` or a file for the message ID, and
    /// deliberately not "HTML can be loaded": a row whose URI dangles still routes to the
    /// preview card on fallback text, and the card's pipeline then recovers the HTML.
    static func cheapTerms(
        for inputs: RichContentVerdictInputs,
        storedHTML: StoredHTML,
        handler: HTMLContentHandler,
        generation: HTMLContentAccountGeneration?
    ) -> CheapTerms {
        guard !inputs.isFromMe else { return .decided(false) }
        guard NewsletterFallbackText.looksLikeFallbackText(inputs.bodyText ?? inputs.snippet) else {
            return .classifierDecides
        }

        let hasHTMLSource: Bool
        switch storedHTML {
        case .justSaved:
            hasHTMLSource = true
        case .readThroughHandler:
            hasHTMLSource = inputs.bodyStorageURI != nil ||
                handler.htmlFileExists(for: inputs.messageID, expectedGeneration: generation)
        }
        return hasHTMLSource ? .decided(true) : .classifierDecides
    }

    /// The HTML the classifier runs on: the message's own file, else the file at
    /// `bodyStorageURI`, else HTML embedded in a raw-source `bodyText`, else `bodyText` itself
    /// when it carries HTML tags.
    ///
    /// Any file that exists and loads wins, whatever it contains: an empty file classifies as
    /// not rich and does not fall through to the next candidate.
    static func classifierCandidate(
        for inputs: RichContentVerdictInputs,
        storedHTML: StoredHTML,
        handler: HTMLContentHandler,
        generation: HTMLContentAccountGeneration?
    ) -> ClassifierCandidate {
        switch storedHTML {
        case .justSaved(let html):
            return .html(html)
        case .readThroughHandler:
            break
        }

        if handler.htmlFileExists(for: inputs.messageID, expectedGeneration: generation) {
            guard let html = handler.loadHTML(for: inputs.messageID, expectedGeneration: generation) else {
                return .undetermined
            }
            return .html(html)
        }

        if let bodyStorageURI = inputs.bodyStorageURI,
           let url = StorageURIResolver.resolve(bodyStorageURI),
           FileManager.default.fileExists(atPath: url.path) {
            guard let html = handler.loadHTML(from: url, expectedGeneration: generation) else {
                return .undetermined
            }
            return .html(html)
        }

        guard let bodyText = inputs.bodyText else { return .none }
        if let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: bodyText) {
            return .html(rawSourceHTML)
        }
        return ChatBubbleTextProcessor.containsHTMLTags(bodyText) ? .html(bodyText) : .none
    }

    /// The verdict for a message's stored state, or `.unknown` when that state could not be
    /// read. Synchronous, for the writers; the loader composes the two steps itself.
    ///
    /// `.unknown` is never a guess at "not rich". Every handler read answers "absent" when
    /// the account boundary is closed or `expectedAccountGeneration` is stale, so an
    /// evaluation that ends on a stale generation says nothing about the row, and a persisted
    /// "not rich" from it would render a rich row's text at mount and then swap it for a
    /// card on every open.
    ///
    /// - Parameter classify: the classifier, replaceable so sync can substitute the answer it
    ///   pre-computed for the exact string it saved (`MessagePersister.richContentPrerun`).
    static func verdict(
        for inputs: RichContentVerdictInputs,
        storedHTML: StoredHTML = .readThroughHandler,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil,
        classify: (String) -> Bool = RichContentClassifier.hasGenuineRichContentAfterCleanup
    ) -> RichContentVerdict {
        guard !inputs.isFromMe else { return .notRich }

        let generation: HTMLContentAccountGeneration?
        switch storedHTML {
        case .justSaved:
            // Nothing below reads through the handler.
            generation = nil
        case .readThroughHandler:
            guard let captured = expectedAccountGeneration ?? handler.captureAccountGeneration() else {
                return .unknown
            }
            generation = captured
        }

        let isRich: Bool
        switch cheapTerms(for: inputs, storedHTML: storedHTML, handler: handler, generation: generation) {
        case .decided(let decided):
            isRich = decided
        case .classifierDecides:
            switch classifierCandidate(
                for: inputs,
                storedHTML: storedHTML,
                handler: handler,
                generation: generation
            ) {
            case .html(let html):
                isRich = classify(html)
            case .none:
                isRich = false
            case .undetermined:
                return .unknown
            }
        }

        if let generation, !handler.isAccountGenerationCurrent(generation) {
            return .unknown
        }
        return RichContentVerdict(isRich: isRich)
    }
}
