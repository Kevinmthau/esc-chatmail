# Production Hardening Refactor Plan

This plan prioritizes correctness, Core Data consistency, sync reliability,
performance, and architectural boundaries. It intentionally avoids cosmetic
cleanup and broad rewrites.

## A. Highest-Risk Areas

### 1. Foreground and Background Sync Lack One Serialized Boundary

- Fragile: `SyncEngine` uses `SyncStateActor`, but `BackgroundSyncManager` and
  `BackgroundMessageProcessor` bypass that lock while still mutating messages,
  rollups, and history cursors.
- Production risk: foreground and background sync can overlap, process the same
  Gmail history, and save competing state from different contexts.
- User symptoms: missed messages, stale unread/archive state, conversations
  jumping after a foreground refresh, or history cursor drift.
- Root cause: foreground sync locking is local to `SyncEngine`; background sync
  treats `SyncEngine` as a persistence helper rather than participating in one
  sync transaction model.

### 2. Conversation Routing Can Attach Messages to Hidden Archived Threads

- Fragile: `ConversationManager` documents active-only lookup, but
  `ConversationCreationSerializer` fetches any conversation by
  `participantHash` with `fetchLimit = 1`. `MessageConversationRouter` only
  reactivates when the processed message has `INBOX`.
- Production risk: sent, archived, or non-inbox messages can attach to an
  archived conversation and remain hidden.
- User symptoms: sent messages or replies appear to disappear, or new work is
  merged into an old archived thread.
- Root cause: participant identity, Gmail thread reuse, and archive
  reactivation policy are split across multiple types with inconsistent rules.

### 3. Optimistic Send Rollback Can Drift from Persisted Conversation State

- Fragile: `GmailSendService+OptimisticUpdates` mutates conversation date,
  snippet, and archive state, keeps the optimistic graph unsaved until success.
  Done 2026-04-26: failure cleanup now recomputes or restores affected
  conversation rollups. Remaining risk: `OutboundSendMutationTracker` is
  in-memory only.
- Production risk: failed sends can leave stale list metadata, unarchived empty
  threads, or lost failure state after relaunch.
- User symptoms: a conversation appears delivered, revived, or reordered even
  though the send failed.
- Root cause: optimistic mutations lack a durable lifecycle and rollback
  snapshot for conversation-level state.

### 4. Chat Paging Uses a Different Message Universe Than `ChatView`

- Fragile: `ChatView` excludes `DRAFT`, `SPAM`, and `TRASH`, but
  `VirtualScrollState.loadMessagePage` and `loadPendingMessagePage` fetch only
  by `conversation.id`.
- Production risk: virtual counts and visible rows can diverge from the
  `FetchedResults<Message>` collection used by the chat UI.
- User symptoms: wrong rows, broken message grouping, scroll jumps, and
  off-by-one behavior around page boundaries.
- Root cause: duplicated Core Data predicates instead of one shared
  chat-visible message query.

### 5. Conversation Rollups Are Not Always Authoritative Snapshots

- Fragile: `ConversationRollupUpdater` does not clear `latestInboxDate` when no
  inbox messages remain, and does not clear `lastMessageDate` or `snippet` when
  no visible messages remain. `ConversationMerger.merge` updates
  `winner.lastMessageDate` before comparing snippet recency.
- Production risk: derived fields can retain stale values after deletion,
  archive, spam, trash, or merge operations.
- User symptoms: stale previews, stale ordering, wrong unread counts, or wrong
  inbox/archive state.
- Root cause: rollup code applies partial mutations instead of assigning from a
  complete derived snapshot.

### 6. HTML Preview Loading Repeats Expensive Work and Has Fragmented Caches

- Fragile: `EmailContentSection` loads canonical HTML, classifies it, lets
  builders re-parse text/images, and may then fall back to
  `loadContentWithTimeout`. `HTMLContentLoader` also uses singleton recovery
  and cache keys that rely on invalidation rather than the full HTML source
  signature.
- Production risk: expensive repeated regex/HTML work during scroll and stale
  preview/full-message output when invalidation misses a path.
- User symptoms: janky chat scrolling, stale preview cards, delayed WebView
  fallback rendering.
- Root cause: there is no single preview source snapshot shared by
  classifiers, preview builders, and renderers.

### 7. Reconciliation Can Silently Miss Label Drift

- Fragile: `SyncReconciliation` skips label reconciliation when history reports
  no changes, checks only the first 100 recent messages, and fetches metadata
  through `GmailAPIClient.shared` instead of the injected fetcher/client.
- Production risk: missed archive/unread transitions can remain local truth.
- User symptoms: unread counts and inbox/archive state stay wrong until a later
  full cleanup or unrelated sync.
- Root cause: reconciliation is partly outside the sync dependency boundary and
  has a separate bounded query policy.

### 8. Conversation-List Read/Unread Actions Still Do Per-Message Work

- Fragile: `MessageActions.markConversationAsRead` loops unread inbox messages,
  saving and queuing each action. Chat uses `markMessagesAsReadBatch`, but the
  list path does not.
- Production risk: slow taps/swipes and larger race windows with pending action
  processing.
- User symptoms: list lag on large unread threads, delayed badge updates, and
  excessive pending-action traffic.
- Root cause: batching exists but is not the default conversation-level API.

## B. Best Refactor Targets

- `SyncEngine`, `BackgroundSyncManager`, `BackgroundMessageProcessor`,
  `PendingActionsManager`: introduce one sync-run coordinator that owns
  foreground/background exclusion, run identity, context creation, cursor
  advancement, final rollup save, and notification posting.
- `ConversationCreationSerializer`, `MessageConversationRouter`,
  `ConversationRollupUpdater`, `ConversationMerger`: split routing policy from
  rollup calculation. Add an authoritative `ConversationRollupSnapshot`
  computed from visible/inbox messages and assigned consistently.
- `ChatView`, `VirtualScrollState`, `MessageActions`: centralize the
  chat-visible message predicate so list fetches, virtual paging, unread
  snapshots, and counts all agree.
- `ChatDependencies`: split into narrower groups for content/rendering,
  actions, compose/reply/forward, contacts, and Core Data. Recent narrowing
  helped, but `ChatViewModel` still receives too much app surface.
- `EmailContentSection`, `HTMLContentLoader`, `NewsletterPreviewBuilder`,
  `TransactionalPreviewBuilder`, `MessageBubbleLoader`: add an
  `EmailPreviewSourceLoader` that returns canonical HTML, source signature,
  extracted text, extracted images, and classification once.
- `CacheCoordinator`, `MessagePersister+Updates`, `HTMLContentHandler`,
  `ProcessedTextCache`, `HTMLContentLoader`: define one message-content
  invalidation contract, ideally keyed by stable content revision/source
  signature instead of scattered manual invalidations.
- `GmailSendService+OptimisticUpdates`, `OutboundSendMutationTracker`,
  `OutboundMessageCoordinator`: make optimistic send state durable enough to
  survive failure/relaunch and restore conversation rollups.

## C. Performance Opportunities

### Quick Wins

- Align `VirtualScrollState` predicates with `ChatView` to avoid loading and
  counting draft/spam/trash rows the UI cannot render.
- Done 2026-04-25: Routed conversation-list mark-read through the existing
  batch read path with one pending action batch.
- Stop canceling every `ProcessedTextCache.prefetch` batch during rapid scroll;
  coalesce requests or let a bounded queue drain.
- Include `bodyStorageURI` and HTML source signatures in text/HTML prefetch paths
  so cache misses do not force later bubble recomputation.
- Snapshot participant emails into `ConversationSnapshot` or a filter snapshot
  so contact filtering does not fault through participants/persons on the main
  actor.

### Deeper Structural Fixes

- Build preview cards from one parsed/source snapshot instead of each
  classifier and builder extracting text/images separately.
- Replace repeated ad hoc HTML attribute/tag regex passes in preview builders
  with one constrained parser or intermediate representation.
- Move expensive message/content mapping out of SwiftUI body-derived load keys
  where possible; use stable revision values instead of repeated `hashValue`
  work.
- Make rollup recomputation batch-oriented after sync/action transactions
  instead of scattered across label processors, message persisters, mergers, and
  UI actions.

## D. Hardening Plan

### Phase 1: Highest-Impact Low-Risk Fixes

1. Done 2026-04-25: Centralized chat-visible message predicates and updated
   `VirtualScrollStateTests`.
2. Done 2026-04-25: Fixed rollup clearing and `ConversationMerger`
   snippet/date ordering; added focused rollup and merge tests.
3. Done 2026-04-25: Changed conversation-list mark-read to use batch read
   updates and one pending action batch.
4. Done 2026-04-25: Routed
   `SyncReconciliation.fetchGmailMetadataInParallel` metadata fetches through
   the injected `MessageFetcher` instead of `GmailAPIClient.shared`.
5. Done 2026-04-25: Made Core Data startup/readiness waiting fail immediately
   on stored terminal load errors instead of only timing out.

### Phase 2: Architectural Refactors

1. Done 2026-04-26: Added a shared sync-run coordinator used by foreground and
   background sync, plus pending action processing, before sync-owned Core Data
   mutations or history cursor updates.
2. Extract conversation routing policy and authoritative rollup snapshot
   assignment.
3. Add durable optimistic-send mutation records or rollback snapshots for
   conversation state.
4. Introduce `EmailPreviewSourceLoader` and route preview classifiers/builders
   through it.
5. Split `ChatDependencies` and shrink `ChatViewModel` orchestration
   responsibilities.

### Phase 3: Deeper Cleanup and Future-Proofing

1. Consolidate HTML/CSS parsing for previews and reduce builder-specific regex
   parsing.
2. Replace scattered cache invalidation with a message content
   revision/source-signature model.
3. Add sync reconciliation metrics and developer-visible failure counters for
   skipped/capped reconciliation.
4. Revisit one-time migrations so flags are set only after verified successful
   mutation.
5. Audit unused or partially wired Core Data indexes/search infrastructure
   before relying on it.

## E. Patch Candidates

### 1. Align Chat Virtual-Scroll Predicates

- Status: Completed 2026-04-25.
- Why this is the right next patch: it is a concrete correctness bug with low
  blast radius and direct user-visible impact on chat scrolling.
- Files to change:
  - `esc-chatmail/Views/Chat/ChatView.swift`
  - `esc-chatmail/ViewModels/VirtualScrollState.swift`
  - `esc-chatmailTests/VirtualScrollStateTests.swift`
- Implementation approach:
  - Add a shared chat-visible message predicate helper.
  - Use it for `ChatView` fetches and both persisted/pending virtual-scroll page
    and count fetches.
  - Preserve `includesPendingChanges` differences where they are intentional.
- Tests:
  - Excluded-label messages are omitted from page IDs.
  - Excluded-label messages are omitted from total counts.
  - Valid pending messages still appear in the pending page path.

### 2. Fix Stale Conversation Rollups

- Status: Completed 2026-04-25.
- Why this is the right next patch: stale rollup fields directly affect list
  ordering, snippets, unread state, and archive visibility.
- Files to change:
  - `esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift`
  - `esc-chatmail/Services/Conversation/ConversationMerger.swift`
  - `esc-chatmailTests/ConversationMergerTests.swift`
  - `esc-chatmailTests/ConversationRollupUpdaterTests.swift`
- Implementation approach:
  - Clear `latestInboxDate` when there are no inbox messages.
  - Clear `lastMessageDate` and `snippet` when there are no visible messages, if
    that is the intended empty-thread behavior.
  - In `ConversationMerger.merge`, capture old winner/loser dates before
    assigning the merged date, then choose snippet from the newer source.
- Tests:
  - No inbox messages clears `latestInboxDate`.
  - No visible messages clears stale visible metadata.
  - Merge keeps the snippet from the newest conversation.

### 3. Harden Optimistic-Send Failure Cleanup

- Status: Completed 2026-04-26.
- Why this is the right next patch: failed sends should not leave durable
  conversation-list drift.
- Files to change:
  - `esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift`
  - `esc-chatmailTests/Send/GmailSendServiceOptimisticFailureTests.swift`
  - Potentially `ConversationRollupUpdater` or a small rollback helper.
- Implementation approach:
  - Capture affected conversation identity/state before deleting or marking the
    optimistic message failed.
  - Recompute or restore the conversation rollup after cleanup.
  - Handle the case where optimistic send unarchived an archived conversation.
- Tests:
  - Failed send after optimistic unarchive restores archive/list state.
  - Failed send without attachments does not leave an empty stale conversation.
  - Failed send with local attachments keeps the failed bubble while preserving
    correct rollup state.

## Recommended Next Steps

1. Next architectural refactor: extract conversation routing policy and
   authoritative rollup snapshot assignment.
2. Smaller remaining quick wins: coalesce `ProcessedTextCache.prefetch`
   cancellation, include `bodyStorageURI`/source signatures in prefetch keys, or
   snapshot participant emails for contact filtering.

Follow-up implementation prompt:

> Extract conversation routing policy and authoritative rollup snapshot
> assignment. Inspect `ConversationCreationSerializer`,
> `MessageConversationRouter`, `ConversationRollupUpdater`, and
> `ConversationMerger`; ensure participant-hash routing, Gmail thread reuse,
> archive reactivation, and derived rollup fields use one explicit policy.
