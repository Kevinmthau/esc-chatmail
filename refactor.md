# Architectural Refactor Plan

Last reviewed: 2026-05-21

This plan is a scoped refactor backlog for `esc-chatmail`. It replaces the older architectural review as the working version. Treat each item as an independent change: inspect the current code first, keep diffs small, and do not refactor unrelated paths while implementing one item.

## Current Priorities

### P0. Make outbound sends idempotent after remote success

**Status:** Implemented 2026-05-21.

**Where:**
- `esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift`
- `esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift`
- `esc-chatmail/Services/Send/OutboundMessageCoordinator.swift`
- `esc-chatmail/Services/Send/OutboundSendMutationTracker.swift`
- `esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld`

**Problem:**
The send path has a durable optimistic mutation record, but it does not persist a remote-committed Gmail message ID before reconciling the optimistic local message. If Gmail accepts the send and local reconciliation then fails, retry behavior can still duplicate a message remotely or leave the local optimistic message in an ambiguous state.

**Direction:**
Add durable remote-commit state, such as `remoteCommittedMessageId` and `remoteCommittedThreadId`, to the optimistic send mutation record or associated message state. Persist that state immediately after Gmail returns success and before mutating the optimistic message ID or deleting the mutation record. On retry, presence of the remote-committed ID must mean "skip remote send, reconcile locally only."

**Implementation note:**
`OutboundSendMutationRecord` now stores the remote Gmail message/thread IDs after Gmail accepts a send. Background retries and launch-time reconciliation skip the remote send when those IDs exist, reconcile the optimistic local message only, and remove any superseded optimistic duplicate if sync already fetched the real Gmail message.

**Verification:**
Add tests for "remote send succeeds, local reconciliation save fails, retry does not call Gmail send again." Run targeted send suites first:

```bash
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/ComposeSendOrchestratorTests'
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/OutboundMessageCoordinatorTests'
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/GmailSendServiceOptimisticFailureTests'
```

### P1. Reuse WebKit process configuration for email rendering

**Status:** Still relevant.

**Where:**
- `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`
- `esc-chatmail/Services/WebKitPrewarmer.swift`
- `esc-chatmail/Services/Dependencies.swift`

**Problem:**
`BaseEmailWebView` creates a fresh `WKWebViewConfiguration` for every email WebView. `WebKitPrewarmer` warms a throwaway `WKWebView`, but the actual rendering path does not share a `WKProcessPool` or a common non-persistent `WKWebsiteDataStore`. Large threads and preview-heavy lists can pay repeated WebKit startup and process churn costs.

**Direction:**
Start with a shared `WKProcessPool` and non-persistent data store owned by `WebKitPrewarmer` or injected through dependencies, then use them in every `BaseEmailWebView` configuration. Consider a small preview WebView pool only after measuring the shared-process-pool change. Keep full-message fidelity separate from preview behavior.

**Verification:**
Run `BaseEmailWebViewTests` and manually inspect a long conversation with many rendered emails. Measure WebContent process count and first-paint behavior before and after if possible.

### P1. Bound pending-action run acquisition

**Status:** Still relevant.

**Where:**
- `esc-chatmail/Services/PendingActionsManager.swift`
- `esc-chatmail/Services/PendingActions/PendingActionProcessor.swift`
- `esc-chatmailTests/PendingActionsManagerTests.swift`

**Problem:**
`acquirePendingActionRun()` loops forever while waiting for the sync run coordinator. If an active sync is wedged or never reaches idle, pending actions can wait indefinitely.

**Direction:**
Add a bounded wait policy. After a reasonable timeout, either proceed with a reduced-priority pending-action run if the coordinator allows it, or mark/surface the pending state so the user knows changes are stuck. Preserve the existing abandoned-action behavior for retry exhaustion.

**Verification:**
Add a test with a wedged sync coordinator and assert pending-action processing does not wait forever.

## Revisit Opportunistically

### Message persistence batching and actor serialization

**Status:** Partially addressed.

Main sync now uses batched `saveMessages`, concurrent preparation, and per-batch saves. `MessagePersister` remains an actor, persistence remains serialized, and background sync still saves messages one at a time.

Revisit only if sync profiling shows persistence is still the dominant bottleneck. The next step would be to batch background sync persistence and reduce small `context.perform` blocks before removing actor isolation.

### Core Data save failure handling

**Status:** Partially addressed.

Main sync uses throwing saves for final history advancement, and pending-action queueing checks save success. Some paths still use `saveIfNeeded` / `saveOrLog` and only log failure.

Revisit by adding a throwing save helper for user-data-critical paths only. Do not convert every best-effort save.

### Background sync continuation state

**Status:** Partially addressed.

Foreground sync keeps history ID advancement with the final Core Data save. Background sync still stores continuation state in `UserDefaults` while history ID lives in Core Data.

Revisit if background catch-up drift appears in logs or tests. The durable fix is to move continuation fields onto `Account` and write them transactionally with the processed page state.

### User-facing send and fetch errors

**Status:** Partially addressed.

`ComposeViewModel` has error state and an alert. `ChatViewModel.sendReply` still logs optimistic-creation failures and returns `false` with no published error. `VirtualScrollState` still uses `try?` for several fetch/count paths.

Revisit narrowly around chat send failure first. Avoid turning low-value fetch misses into noisy UI alerts.

### Preview height measurement

**Status:** Partially addressed.

Preview height measurement now hooks into `didFinish`, but still uses delayed JavaScript measurements. A `ResizeObserver`-based measurement path may be cleaner, but this area can destabilize scrolling and should only change with targeted tests/manual verification.

### CoreDataStack isolation

**Status:** Still relevant but lower urgency.

`CoreDataStack` still uses `@unchecked Sendable` and a serial `DispatchQueue` for mutable load state. A companion actor for async state would reduce release-build deadlock risk, but it should not be mixed into unrelated persistence changes.

## Mostly Resolved Or Stale

### HTML meaningful-content regex loop

The loop is now bounded with `maxHiddenElementStripPasses`, and there is a regression test for deep nested hidden preheader markup. No further work unless new adversarial HTML cases appear.

### Preview classification cache

`EmailPreviewSourceLoader` now caches preview source and classification results with an `NSCache` keyed by message/source/mode. Revisit only if scroll profiling shows classification remains hot.

### Token refresh shared failure

The refresh coordinator is cleared on failure, and there is single-flight test coverage for concurrent refresh callers. Revisit only if real retry/backoff behavior under spotty network conditions proves problematic.

### Sync observability

Sync phase timing and signposts already exist around the main sync phases. Add more only when investigating a measured slow path.
