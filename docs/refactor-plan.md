# ESC Chatmail Refactor Plan

This plan prioritizes correctness, user-visible reliability, and performance in the iOS app. It intentionally avoids cosmetic cleanup, broad rewrites, and architecture churn unless the change removes a real production risk.

## Principles

1. Fix concrete bugs before restructuring code.
2. Keep diffs small enough to review and revert safely.
3. Preserve full-message email fidelity unless a behavior is clearly wrong.
4. Keep preview-specific shortcuts out of the original-message rendering path.
5. Prefer source signatures and authoritative snapshots over manual invalidation and partial mutation.
6. Add regression tests for every bug fix that can be tested without brittle UI automation.
7. Run targeted tests first, then broader suites when shared infrastructure is touched.

## Current Highest-Risk Areas

### 1. WebView and inline attachment correctness

Risk: `BaseEmailWebView` creates a `CIDSchemeHandler` once in `makeUIView`. SwiftUI can reuse the same WebView for a different message, but `updateUIView` does not currently refresh the handler's `message` reference. This can make `cid:` inline images resolve against the wrong message, disappear, or return the transparent-pixel fallback.

User symptoms:

- Inline email images randomly missing.
- The same message sometimes renders differently after scrolling or reopening.
- A reused WebView shows stale attachment behavior.

Preferred fix:

- Update `context.coordinator.cidHandler?.message = message` in `BaseEmailWebView.updateUIView`.
- Include a stable message identity in the WebView reload signature when cid attachments are possible.
- Add focused tests around `CIDSchemeHandler` content-id matching and WebView coordinator state if practical.

### 2. HTML URL sanitization gaps

Risk: `HTMLURLSanitizer` handles quoted `href` and `src` attributes, but valid unquoted attributes can bypass the sanitizer regex. CSP and navigation policy reduce the blast radius, but hostile email HTML should be sanitized at the source layer.

User symptoms:

- Unsafe or malformed email HTML survives sanitization.
- Security behavior depends too much on WebKit navigation policy instead of the sanitizer.

Preferred fix:

- Extend attribute scanning to handle quoted and unquoted `href` / `src` values.
- Preserve existing entity and percent-decoding protections.
- Add tests for unquoted `javascript:`, encoded `javascript:`, unsafe `data:`, and safe `cid:` / `https:` values.

### 3. WebView load failure retry behavior

Risk: `BaseEmailWebView.Coordinator.loadContent` marks content as loaded before `WKWebView` finishes loading. If the load fails, the failed content signature remains current, so the view may not retry until the HTML or mode changes.

User symptoms:

- Blank email body after a transient WebView load failure.
- Reopening or theme/layout changes fix the issue, but normal refresh does not.

Preferred fix:

- Clear `lastLoadedContent` and `lastLoadedModeSignature` in `didFail` and `didFailProvisionalNavigation`.
- Keep logging lightweight.
- Add a coordinator-level test if possible, otherwise cover through a narrow helper extraction.

### 4. HTML content cache can serve stale output

Risk: `HTMLContentLoader` caches wrapped output by message ID and display variants, but not by canonical source signature. If recovered HTML, stored HTML, raw source extraction, or attachment fallback output changes without perfect invalidation, stale preview/original HTML can persist.

User symptoms:

- A message continues showing old HTML after recovery or content rewrite.
- Preview and original views disagree.
- Scrolling reuses stale preview output.

Preferred fix:

- Introduce a stable source signature for canonical HTML.
- Include that signature in cache keys for preview and original rendering.
- Prefer deriving the signature from the canonical HTML bytes, or from file URI plus modification date and size before loading.
- Keep manual invalidation, but stop relying on it as the only correctness boundary.

### 5. Preview loading repeats expensive parsing and classification

Risk: Preview rendering loads canonical HTML, classifies content, extracts text/images, and may fall back to WebView rendering through separate paths. This duplicates regex and HTML work during scroll and makes cache invalidation fragmented.

User symptoms:

- Janky chat scrolling.
- Slow preview card appearance.
- Stale or inconsistent preview cards.

Preferred fix:

- Add an `EmailPreviewSourceLoader` that returns one immutable source snapshot per message/display variant.
- Route newsletter previews, transactional previews, text extraction, image extraction, and WebView fallback through that snapshot.
- Key caches by message ID plus source signature plus display mode.

### 6. Optimistic send state is still not durable enough

Risk: Optimistic send cleanup now recomputes or restores affected conversation state, but mutation tracking is still mostly in-memory. A relaunch during send or failure can lose rollback context.

User symptoms:

- A failed send leaves a conversation bumped, unarchived, or with stale snippet/date.
- A failed optimistic bubble state is inconsistent after relaunch.

Preferred fix:

- Add durable optimistic-send mutation records or rollback snapshots.
- Persist enough conversation state to restore archive, hidden, display name, date, and snippet deterministically.
- Reconcile durable send records at startup.

### 7. Sync and reconciliation need better observability

Risk: The shared sync-run coordinator now serializes foreground, background, and pending action processing, but the app still needs better visibility into skipped reconciliation, capped metadata checks, and drift repair.

User symptoms:

- Unread/archive state remains wrong until a later sync or manual refresh.
- Hard-to-debug sync drift with little developer visibility.

Preferred fix:

- Add counters/logs for reconciliation caps, skipped checks, metadata fetch failures, and repaired label drift.
- Keep this diagnostic-only unless it reveals a concrete correction bug.

## Phased Plan

## Phase 1: Immediate correctness fixes

Goal: fix concrete bugs with small, low-risk patches before starting broader refactors.

Status as of 2026-05-04:

- 1.1 complete: WebView coordinator updates the CID handler message and reload signatures include message identity.
- 1.2 complete: URL sanitization scans quoted and unquoted `href` / `src` attributes, with focused regression coverage.
- 1.3 complete: WebView navigation failures clear loaded signatures so failed loads can retry.
- 1.4 complete: `HTMLContentLoader` cache keys include canonical source signatures, with stale-cache regression coverage.
- Phase 1 is complete.

### 1.1 Refresh cid handler state on WebView reuse

Files:

- `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`
- `esc-chatmail/Services/CIDSchemeHandler.swift`
- Tests if practical: new `CIDSchemeHandlerTests` or coordinator helper tests

Implementation:

- Update the coordinator's cid handler with the latest `message` in `updateUIView`.
- Add message identity to the mode/reload signature if a stale cid graph can survive with identical HTML.
- Verify full-message rendering and preview rendering still behave differently where intended.

Validation:

- Run HTML/WebView-adjacent tests.
- Manually inspect full-message cid image behavior in simulator if possible.

### 1.2 Harden URL attribute sanitization

Files:

- `esc-chatmail/Services/HTMLSanitization/HTMLURLSanitizer.swift`
- `esc-chatmailTests/HTMLSanitization/HTMLSanitizerServiceTests.swift` or a new focused URL sanitizer test suite

Implementation:

- Replace quoted-only `href` / `src` regex logic with attribute scanning that supports quoted and unquoted values.
- Preserve existing normalization and modern image format rewrite behavior.
- Do not rewrite safe `cid:` sources.
- Keep safe relative URLs allowed.

Validation:

- Add regression tests for quoted and unquoted unsafe values.
- Add safe-case tests for `https:`, `mailto:`, `tel:`, `cid:`, relative paths, fragments, and safe image data URLs.

### 1.3 Reset loaded signatures after WebView failure

Files:

- `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`

Implementation:

- Clear loaded content and mode signature in both navigation failure callbacks.
- Avoid infinite retry loops. The next SwiftUI update/layout should be enough to retry.

Validation:

- Build.
- Add a narrow coordinator helper test only if this can be made non-brittle.

### 1.4 Add canonical HTML source signatures to cache keys

Files:

- `esc-chatmail/Services/HTMLContentLoader.swift`
- Related cache tests if present, otherwise add focused loader cache tests

Implementation:

- Compute a `sourceSignature` for canonical HTML after selecting the source and before wrapping.
- Include `sourceSignature` in preview/original cache keys.
- Preserve existing invalidation behavior.
- Avoid hashing multiple times on hot paths when the source snapshot can carry the signature forward.

Validation:

- Add tests showing the same message ID with changed canonical HTML does not return stale wrapped output.
- Run HTML loader and display wrapper tests.

## Phase 2: Preview pipeline consolidation

Goal: reduce repeated HTML work during scroll and make preview behavior more predictable.

Status as of 2026-05-05:

- 2.1 complete: preview routing now uses `EmailPreviewSourceLoader` snapshots for canonical HTML, source signatures, text/image extraction, and classification.
- 2.2 complete: preview-derived cache keys now carry source signatures through preview source snapshots, HTML preview height keys, chat-bubble processed text, and source-aware load signatures.
- 2.3 complete: common preview extraction now carries HTML summaries for titles, preheaders, action links, text, and images so newsletter and transactional builders no longer run their own overlapping HTML regex extraction when using source snapshots.
- Phase 2 is complete.

### 2.1 Introduce `EmailPreviewSourceLoader`

New model:

```swift
struct EmailPreviewSource: Sendable {
    let messageId: String
    let sourceSignature: String
    let canonicalHTML: String?
    let plainText: String?
    let extractedText: String?
    let extractedImages: [EmailPreviewImage]
    let classification: EmailPreviewClassification
}
```

Files likely involved:

- `esc-chatmail/Services/HTMLContentLoader.swift`
- `esc-chatmail/Views/Components/EmailContent/EmailContentSection.swift`
- `esc-chatmail/Services/Preview/NewsletterPreviewBuilder.swift`
- `esc-chatmail/Services/Preview/TransactionalPreviewBuilder.swift`
- `esc-chatmail/ViewModels/MessageBubbleLoader.swift`
- Related preview/classifier tests

Implementation:

- Build a source loader that selects canonical HTML once.
- Extract preview text/images once.
- Classify once.
- Return one immutable snapshot to preview builders and fallback renderers.
- Keep full-message original rendering outside this preview-specific path.

Validation:

- Existing newsletter, transactional, classifier, and message bubble tests should still pass.
- Add tests proving builders reuse snapshot data rather than reparsing where practical.

### 2.2 Move preview cache keys to source signatures

Implementation:

- Key preview-derived caches by `messageId + sourceSignature + preview mode`.
- Remove redundant or fragile invalidation where source signatures make it unnecessary.
- Keep explicit invalidation for memory cleanup and major message mutations.

Validation:

- Test changed body storage/source HTML invalidates preview output without manual invalidation.
- Watch scroll performance and cache hit behavior.

### 2.3 Reduce builder-specific regex passes

Implementation:

- After the source loader is stable, consolidate common extraction logic.
- Do not introduce a heavy parser unless it clearly improves correctness or performance.
- Keep newsletter/transactional builder logic focused on presentation decisions.

Validation:

- Preserve existing preview snapshots.
- Add regression fixtures for complex newsletter HTML.

## Phase 3: Durable optimistic send lifecycle

Goal: make send failure and relaunch behavior deterministic.

Status as of 2026-05-05:

- 3.1 complete: optimistic sends now create durable Core Data rollback records with conversation state snapshots, success/failure clears those records, failure cleanup can restore persisted snapshots after an intervening save, and startup reconciles abandoned optimistic sends.
- Phase 3 is complete.

### 3.1 Add durable optimistic send mutation records

Files likely involved:

- `esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift`
- `esc-chatmail/Services/Send/OutboundSendMutationTracker.swift`
- `esc-chatmail/Services/Send/OutboundMessageCoordinator.swift`
- Core Data model if a durable entity is needed
- Send failure tests

Implementation:

- Persist a rollback snapshot when an optimistic send mutates conversation-level fields.
- Track message ID, conversation ID, archivedAt, hidden, displayName, lastMessageDate, snippet, and whether the conversation was newly inserted.
- On send success, clear the durable record.
- On send failure, restore from the durable record or recompute rollups when safer.
- On startup, reconcile abandoned optimistic records.

Validation:

- Failed send after optimistic unarchive restores archive/list state.
- Relaunch during send failure does not leave stale conversation state.
- Failed send with local attachments keeps failed attachment/bubble state while preserving rollups.

## Phase 4: Sync and reconciliation observability

Goal: make sync drift detectable and easier to repair.

Status as of 2026-05-06:

- 4.1 complete: reconciliation now emits structured diagnostics for checked messages, skipped checks, metadata failures, drift found/repaired, and capped missed-message scans; sync timing includes the summary and focused reconciliation coverage exercises cap and metadata-failure reporting.

### 4.1 Add reconciliation diagnostics

Files likely involved:

- `esc-chatmail/Services/Sync/SyncReconciliation.swift`
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift`
- `esc-chatmail/Services/Sync/SyncEngine.swift`

Implementation:

- Add structured counters for messages checked, messages skipped, metadata fetch failures, drift found, drift repaired, and reconciliation capped.
- Keep logs low volume.
- Prefer diagnostic records that can be inspected in development builds.

Validation:

- Existing sync tests pass.
- Add tests for capped reconciliation and metadata failure reporting if the structure supports it.

### 4.2 Decide whether capped reconciliation should become resumable

Implementation:

- After diagnostics exist, evaluate whether the first-100-message policy is enough.
- If not, add resumable reconciliation windows instead of doing a large unbounded fetch.

Validation:

- Tests for multiple reconciliation windows.
- Ensure no large foreground UI stalls.

## Phase 5: Dependency and view-model narrowing

Goal: reduce orchestration complexity after correctness and performance are stable.

### 5.1 Split chat dependencies by responsibility

Files likely involved:

- `esc-chatmail/Services/ConversationList/ConversationListDependencies.swift`
- `esc-chatmail/ViewModels/ChatViewModel.swift`
- `esc-chatmail/Views/Chat/*`

Implementation:

- Split large dependency containers into narrower groups: rendering/content, message actions, compose/reply/forward, contacts, and Core Data.
- Do not change behavior.
- Avoid moving logic into SwiftUI views.

Validation:

- Existing ChatViewModel tests pass.
- Keep diffs mechanical and reviewable.

### 5.2 Remove obsolete compatibility seams

Implementation:

- After several phases land, delete dead adapters, duplicate helpers, and unused migration scaffolding.
- Only remove code proven unused by search and tests.

Validation:

- Full test suite.
- Build cleanly with no new warnings in touched scope.

## Test Strategy

Use targeted tests first:

- HTML/rendering: `HTMLContentLoaderTests`, `HTMLDisplayWrapperTests`, `HTMLSanitizerServiceTests`, `HTMLRemoteImageAttachmentFallbackTests`, `HTMLPreviewScaleCalculatorTests`
- Preview classification/cards: `NewsletterPreviewBuilderTests`, `TransactionalPreviewBuilderTests`, `EmailPreviewClassifierTests`
- WebView/CID: add focused tests where possible
- Compose/send: `ComposeViewModelTests`, `ComposeSendOrchestratorTests`, `GmailSendServiceOptimisticFailureTests`, `OutboundMessageCoordinatorTests`
- Sync: `SyncRunCoordinatorTests`, `ForegroundSyncCoordinatorTests`, reconciliation tests
- Chat bubble loading: `MessageBubbleLoaderTests`, `MessageBubbleViewModelTests`

Before finishing any phase:

1. Run the narrowest relevant tests.
2. Run broader suites if shared infrastructure changed.
3. Run the app build.
4. Review the diff for behavior changes outside the intended scope.
5. Update this plan if scope or risk changes.

## Recommended Next Patch

Start with Phase 4.2 now that reconciliation diagnostics exist.

Implementation prompt:

> Implement Phase 4.2 of `docs/refactor-plan.md`. Use the reconciliation diagnostics from Phase 4.1 to decide whether capped reconciliation should become resumable. If the first-window policy is not enough, add bounded resumable reconciliation windows instead of an unbounded foreground fetch, add focused tests for multiple windows, then run the relevant sync suites and the iOS build.
