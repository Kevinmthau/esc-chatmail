# Service Decomposition Campaign

Last updated: 2026-06-09

Phase-2 follow-on to the email-rendering rearchitecture (see git history; the
phase-1 closeout `rearchitecture.md` was removed once shipped). This campaign
breaks the remaining large "god-object" services into focused, independently
testable units, one concern per PR, in numbered `(N/n)` series. Each extraction
is behavior-preserving and anchored by characterization tests.

## Working method

1. **Characterize first.** Before moving code, make sure the observable behavior
   is locked by tests driving the existing public API. Add tests for any gap.
2. **Extract one concern per PR.** Move a self-contained responsibility into a
   new type/file; delegate from the original. No behavior change.
3. **Keep the seam explicit.** Shared helpers the extracted unit still needs are
   injected (initializer params / closures), not duplicated.
4. **Verify green** with the relevant `-only-testing` slice before moving on.

## Completed

| Target | PRs | Notes |
|---|---|---|
| CacheCoordinator | #54 | Extracted invalidation planning into a pure function |
| ConversationCache | #55 | Characterization tests for core operations |
| InFlightRequestManager | #56 | Characterized dedup + failure tracking |
| EmailDOMQuoteRemover | #57–#63 | 7-part decomposition (input detection, footers/shared `tagNameNormal`, provider containers, tree-surgery keystone, text markers, structural boundaries, signatures) |
| HTMLContentLoader | #64–#67 | 4-part decomposition (plain-text/HTML conversion, cache-key derivation, source preparation, `HTMLContentResultCache` type) |
| MessageBubbleLoader | #68–#74 | 7-part decomposition (HTML-analysis builder, value types, analysis-cache type, legacy outgoing body fallback, forwarded content, HTML-analysis caching, compatibility content) |
| TransactionalPreviewBuilder | (1–4/n) | 4-part decomposition — extracted four self-contained subsystems (see closeout below). 1519 → 835 lines (−45%). |
| NewsletterPreviewBuilder | (1–3/n) | 3-part decomposition — source-label resolver, hero-image selector, line analyzer (see closeout below). 1093 → 630 lines (−42%). |

## Remaining targets (largest source files, excl. tests)

| File | Lines | Shape | Disposition |
|---|---|---|---|
| `Services/Chat/FullEmailWebViewManager.swift` | 1452 | 17 types, 14 MARK | Already organized; lower priority |
| `Services/ProcessedTextCache.swift` | 1259 | 5 types, 0 MARK | Legacy-compat cache; narrow/delete candidate (pending the data backfill noted in the phase-1 closeout) rather than decompose |
| `Services/ParticipantLoader.swift` | 1104 | 4 types, 3 MARK | Candidate — natural next target |

## TransactionalPreviewBuilder — closeout

Was a single 1519-line struct (219 members, no internal structure). Four
cohesive, self-contained subsystems were extracted, one per PR, each
behavior-preserving and verified against the existing characterization tests
(17/17 pass after every step):

1. **App Store / TestFlight notifications → `AppStoreNotificationPreviewExtractor`** (1/n)
   — detection + metadata extraction for App Store Connect build-processing and
   TestFlight availability emails, plus the `firstRegexCapture(s)` helpers and the
   `AppleDeveloperNotification` / `TestFlightBuildInfo` value types. Added a
   non-Apple-sender negative test.
2. **Reservation parsing → `ReservationPreviewExtractor`** (2/n) — date/party/time
   detail assembly and cancellation subtitles.
3. **Image-candidate selection → `TransactionalImageSelector`** (3/n) —
   `bestCandidate`, `safeImageURL`, `TransactionalImageCandidate`; owns its own
   sanitizer/tracking-remover. Also removed the builder's now-unused
   `urlSanitizer` / `trackingRemover` members.
4. **Line preparation + quality scoring → `TransactionalLineAnalyzer`** (4/n) —
   `cleanedLines`, `previewLines`, `transactionalQualityScore` (body-vs-HTML
   source selection).

Each extractor injects the few shared helpers it still needs (line truncation,
`sanitizeTitle` / `normalizeLine` / `shouldSkipLine` / `transactionLine` /
`firstAmount` / `isLikelyDate`) rather than duplicating them.

### Not extracted: the shared text layer (deliberately deferred)

The remaining ~16 text helpers (`sanitizedTransactionTitle`,
`normalizedCandidateLine`, `normalizedStatus`, `isMeaningfulTitle`, `firstAmount`,
`transactionLine`, `shouldSkipLine`, the `looksLike*` predicates,
`restatesExcludedContent`, `detailFields`/`canonicalDetailField`/`isDetailFieldLabel`,
`sourceLabel`) were **left in the builder**. Unlike the four subsystems above,
they are not a separable concern: they form the builder's intrinsic
text-understanding vocabulary, call each other densely, are used at ~40 sites
across the core resolution methods, and share a web of pattern constants with
both the core (`resolvedActionLabel`, the `lineProcessor` footer config) and the
already-extracted image selector. Extracting them would relocate the builder's
core behind an indirection at high call-site churn and regression risk for
debatable gain. The builder at 835 lines is now a focused resolution
orchestrator + its text vocabulary, which is a coherent unit. Revisit only if a
second consumer genuinely needs this text layer.

## NewsletterPreviewBuilder — closeout

Was a single 1093-line struct (1 type, no internal structure) — the sibling
god-struct to TransactionalPreviewBuilder. Three cohesive, self-contained
subsystems were extracted, one per PR, each behavior-preserving and verified
against the existing characterization tests (29/29 pass after every step):

1. **Source-label resolution → `NewsletterSourceLabelResolver`** (1/n) —
   `sourceLabel` + `normalizedSenderName` + the `ignoredSourceSubdomains` list
   (publisher name from sender display name, else a capitalized primary domain
   segment). Injects only the shared `PreviewLineProcessor` for truncation.
2. **Hero-image selection → `NewsletterHeroImageSelector`** (2/n) —
   `bestCandidate`, `safeHeroImageURL`, `heroImageDisplayMode`, the sizing/hint
   predicates, image-context scoring + followup-line predicates, the
   `HeroImageCandidate` type, and the four hero-hint lists. Owns its
   sanitizer/tracking-remover; injects `previewLines` + `shouldSkipLine` +
   `PreviewLineProcessor`. Also removed the builder's now-unused
   `urlSanitizer` / `trackingRemover` members.
3. **Line preparation + quality scoring → `NewsletterLineAnalyzer`** (3/n) —
   `cleanedLines`, `previewLines`, `previewQualityScore` (body-vs-HTML source
   selection). Exposes `previewLines` so the hero selector sources its line
   preparation from the analyzer rather than the builder.

(2/n and 3/n are direct parallels to `TransactionalImageSelector` /
`TransactionalLineAnalyzer`; there is no Newsletter analog to the Transactional
App Store / reservation extractors, so this builder yields three extractions
rather than four.)

### Not extracted: the shared text + URL-noise layer (deliberately deferred)

The remaining builder (630 lines) is the resolution orchestrator (`buildPreview`,
`resolvedTitle`, `resolvedSubtitle`, `resolvedSnippet`, `normalizedPreviewSummary`)
plus its intrinsic text vocabulary — `shouldSkipLine`, `lineLooksLikePreviewNoise`,
`looksLikeShortTitleCluster`, `startsWithPreviewURLNoise`, `looksLikeNavigationLabelRun`,
`previewWordTokens`, `isMeaningfulTitle`, the boundary trimmers, and the
leading-URL / tracking-classification cluster (`trimmingLeadingPreviewURLNoise`,
`leadingPreviewURLMatch`, `isTrackingLikePreviewURL`, `isUTMTrackingLikePreviewURL`,
`postURLTextLooksLikePreviewTeaser`) with their pattern constants. The
URL-noise cluster looks separable but isn't cleanly: its orchestrator
`postURLTextLooksLikePreviewTeaser` is woven into the text vocabulary
(`shouldSkipLine` / `looksLikeNavigationLabelRun` / `previewWordTokens` /
footer detection) and `trimmingLeadingPreviewURLNoise` sits on the
snippet-resolution hot path (`normalizedPreviewSummary`) — same intrinsic-vocabulary
situation deferred for TransactionalPreviewBuilder. Extracting it would inject
four predicates to relocate the builder's core behind an indirection for
debatable gain. Revisit only if a second consumer needs this layer.

## Validation

The project builds/tests via the iOS simulator (requires Xcode, not just
Command Line Tools). `-only-testing` takes `Target/TestClass` identifiers, NOT
directory paths (e.g. `esc-chatmailTests/Preview` matches zero tests):

```bash
./Scripts/codex-build.sh
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/TransactionalPreviewBuilderTests'
```

If the simulator intermittently fails to launch the test runner
("Application failed preflight checks"), reset and retry:

```bash
xcrun simctl shutdown all
```
