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

## Remaining targets (largest source files, excl. tests)

| File | Lines | Shape | Disposition |
|---|---|---|---|
| `Services/Preview/TransactionalPreviewBuilder.swift` | 1519 | 1 type, 219 members, 0 MARK | **In progress** — decomposing (see below) |
| `Services/Chat/FullEmailWebViewManager.swift` | 1452 | 17 types, 14 MARK | Already organized; lower priority |
| `Services/ProcessedTextCache.swift` | 1259 | 5 types, 0 MARK | Legacy-compat cache; narrow/delete candidate (pending the data backfill noted in the phase-1 closeout) rather than decompose |
| `Services/ParticipantLoader.swift` | 1104 | 4 types, 3 MARK | Candidate |
| `Services/Preview/NewsletterPreviewBuilder.swift` | 1093 | 1 type, 0 MARK | Sibling builder — natural follow-on to TransactionalPreviewBuilder |

## Current target: TransactionalPreviewBuilder

A single struct (219 members, no internal structure) that bundles several
self-contained subsystems. Decomposition plan, one concern per PR:

1. **App Store / TestFlight notifications → `AppStoreNotificationPreviewExtractor`** *(in progress)*
   — 15 functions detecting and extracting App Store Connect build-processing and
   TestFlight availability emails (`appleDeveloperNotification` and helpers), plus
   the `firstRegexCapture(s)` helpers and the `AppleDeveloperNotification` /
   `TestFlightBuildInfo` value types. Injects `PreviewLineProcessor` (truncation)
   and the shared `sanitizeTitle` / `normalizeLine` helpers.
   Anchored by the existing `…AppStoreConnect…` / `…TestFlight…` tests plus a new
   non-Apple-sender negative test.
2. **Reservation parsing → `ReservationPreviewExtractor`** — `resolvedReservation*`,
   `reservationPartySize`, `isStandaloneReservationTime`, etc.
3. **Line cleanup + quality scoring → `TransactionalLineAnalyzer`** —
   `cleanedPreviewLines`, `previewLines`, `transactionalQualityScore`,
   `detailFields`, `shouldSkipLine`, …
4. **Image-candidate selection → `TransactionalImageSelector`** —
   `bestImageCandidate`, `safeImageURL`, `TransactionalImageCandidate`.
5. **Shared text normalization helpers** — `sanitizedTransactionTitle`,
   `normalizedCandidateLine`, `isMeaningfulTitle`, `firstAmount`, … Finish,
   leaving `TransactionalPreviewBuilder` a thin orchestrator. These are the
   helpers injected in steps 1–4, so this step removes the injection seams.

## Validation

The project builds/tests via the iOS simulator (requires Xcode, not just
Command Line Tools):

```bash
./Scripts/codex-build.sh
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/Preview'
```

For a single file slice during decomposition:

```bash
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/Preview/TransactionalPreviewBuilderTests'
```
