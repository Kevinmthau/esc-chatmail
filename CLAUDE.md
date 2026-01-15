# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Simulator
xcodebuild -scheme esc-chatmail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Physical device
xcodebuild -scheme esc-chatmail -destination 'generic/platform=iOS' build
xcrun devicectl device install app --device <DEVICE_ID> path/to/esc-chatmail.app

# Run tests
xcodebuild -scheme esc-chatmail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Run single test class
xcodebuild -scheme esc-chatmail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:esc-chatmailTests/DisplayNameFormatterTests

# Run single test method
xcodebuild -scheme esc-chatmail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:esc-chatmailTests/DisplayNameFormatterTests/testSingleName
```

**Note:** The test target uses file system synchronization - new `.swift` files added to `esc-chatmailTests/` are automatically included.

## Architecture

iOS email client that syncs Gmail and presents emails as chat-style conversations.

```
Gmail API → SyncEngine → Core Data → SwiftUI Views
                ↓
        PendingActionsManager (offline queue) → Gmail API
```

### Directory Structure

```
/App/
  esc_chatmailApp.swift   - App entry point, scene configuration
  FreshInstallHandler.swift - Detects app reinstalls, clears stale keychain data
/Services/
  /API/               - GmailAPIClient (Messages, Labels, History, Attachments)
  /Caching/           - Image caching, conversation preloading, request deduplication
  /Compose/           - Email composition, MIME building, recipient management
  /Contacts/          - CNContact search, contact persistence
  /CoreData/          - CoreDataStack, FetchRequestBuilder, batch operations
  /Fetcher/           - ParallelMessageFetcher, adaptive fetch optimization
  /HTMLSanitization/  - Security pipeline for email HTML
  /ErrorHandling/     - FileSystemErrorHandler for explicit file operation logging
  /Logging/           - Log categories: sync, api, coreData, auth, ui, background, conversation
  /PendingActions/    - Offline action queue with retry logic
  /Security/          - TokenManager, KeychainService, OAuth
  /Sync/              - SyncEngine, orchestrators, persisters, composable phases
  /TextProcessing/    - Email text extraction, quote removal
  Constants.swift     - GoogleConfig, SyncConfig, CacheConfig, NetworkConfig, UIConfig
  Dependencies.swift  - Dependency injection container for testability
/Views/
  /Chat/              - ChatView, MessageBubble, BubbleAvatarView
  /Compose/           - ComposeView, RecipientChip
  /Components/        - Reusable UI: avatars, attachments, skeletons, web views
/ViewModels/          - @MainActor view models with @Published properties
/Models/              - Core Data entity classes
```

### Key Services

- **SyncEngine** - Orchestrates InitialSyncOrchestrator (full sync) and IncrementalSyncOrchestrator (delta sync via History API)
- **ConversationManager** - Groups messages by `participantHash` (normalized emails excluding user's aliases)
- **ConversationCreationSerializer** - Actor preventing duplicate conversations during concurrent processing (throws `ConversationCreationError` on failure)
- **ContactsResolver** - Actor for contact lookup with caching
- **PendingActionsManager** - Actor-based offline action queue with retry logic
- **ProfilePhotoResolver** - Resolves profile photos from contacts and cache
- **ModificationTracker** - Shared actor tracking modified conversations during sync (single source of truth for both MessagePersister and HistoryProcessor)
- **MessagePersister** - Persists Gmail messages to Core Data, delegates modification tracking to ModificationTracker

### Message Display Logic

Messages render differently based on `message.isNewsletter` (detected via Gmail labels, mailing list headers, sender patterns):
- **Newsletter emails** → `MiniEmailWebView` (scaled HTML preview)
- **Personal emails** → Chat bubbles with extracted plain text

### Text Processing Pipeline

Plain text for chat bubbles goes through:
```
HTML/bodyText → extractPlainText() → unwrapEmailLineBreaks() → stripQuotedText()
```

**`unwrapEmailLineBreaks`** handles email line wrapping (RFC 2822 mandates 72-80 char line breaks):
- Normalizes CRLF/CR to LF, special whitespace (NBSP, em space, etc.) to regular space
- Joins lines unless: previous ends with `.!?` OR next starts with uppercase
- Preserves intentional paragraph breaks (blank lines between sentences)

### HTML Content Pipeline

```
HTMLContentLoader (memory cache → disk cache → storage URI → bodyText)
       ↓
HTMLSanitizerService (removes scripts, tracking, dangerous URLs)
       ↓
HTMLContentHandler (file storage in Documents/Messages/)
       ↓
MiniEmailWebView (50% scaled) or HTMLMessageView (full)
```

**HTMLContentLoader** uses NSCache to avoid repeated disk I/O for recently viewed messages. Cache key includes message ID and dark mode flag.

### Caching (Actor-based, LRU)

LRU caches use **timestamp-based eviction** (not array-based) for O(1) access time. The `lastAccessedAt` timestamp in each entry determines eviction order. Eviction scans for oldest timestamp only when cache is full.

- **ProcessedTextCache** - Plain text extractions (500 items, 5MB limit), tracked prefetch task with ID-based cleanup to prevent race conditions
- **AttachmentCacheActor** - Thumbnails (500/50MB) and full images (20/100MB)
- **ConversationCache** - Preloaded conversations (100 items, 5min TTL), 50% clearing on memory warning
- **ConversationPreloader** - Bounded preload queue (100 max) to prevent memory exhaustion during rapid scrolling
- **EnhancedImageCache** - Two-tier cache (memory + disk) for remote images, memory warning observer with stored token
- **DiskImageCache** - Persistent disk cache (7-day TTL, 100MB limit, hourly periodic cleanup, concurrent cleanup prevention)
- **PersonCache** - Email → display name mapping (5min TTL, 1000 max entries, periodic cleanup every 5 minutes)
- **ImageRequestManager** - Failed URL tracking (500 max entries with 20% pruning)
- **AttachmentThumbnailLoader** - Cancels previous task before starting new load to prevent orphaned tasks

**Cache stability patterns:**
- **Bound all collections** - Never let Sets/Dictionaries grow unbounded. Add max size with pruning:
```swift
private let maxFailedURLs = 500
if failedURLs.count >= maxFailedURLs {
    let removeCount = maxFailedURLs / 5  // Remove 20%
    for _ in 0..<removeCount {
        failedURLs.remove(failedURLs.first!)
    }
}
```
- **Periodic cleanup** - Don't rely solely on save-triggered cleanup. Add hourly background cleanup tasks.
- **NSCache totalCostLimit** - Always set both `countLimit` AND `totalCostLimit` for proper memory pressure response.
- **Track prefetch tasks with ID** - Use task IDs to prevent cancelled tasks from clearing newer task references:
```swift
private var activePrefetchTask: Task<Void, Never>?
private var activePrefetchTaskId: UUID?

func prefetch(...) async {
    activePrefetchTask?.cancel()
    let taskId = UUID()
    activePrefetchTaskId = taskId

    activePrefetchTask = Task { [weak self, taskId] in
        // ... do work ...
        await self?.clearPrefetchTaskIfMatches(taskId)
    }
}

private func clearPrefetchTaskIfMatches(_ taskId: UUID) {
    if activePrefetchTaskId == taskId {
        activePrefetchTask = nil
        activePrefetchTaskId = nil
    }
}
```
- **Cancel before reassign** - Always cancel existing tasks before assigning new ones to prevent orphaned tasks:
```swift
func load(...) {
    loadTask?.cancel()  // Prevent orphaned task
    loadTask = Task { ... }
}
```
- **Prevent concurrent cleanup** - Use flags to prevent multiple cleanup operations from racing:
```swift
private var isCleaningUp = false

func save(...) {
    if shouldCleanup && !isCleaningUp {
        isCleaningUp = true
        Task { await cleanup(); isCleaningUp = false }
    }
}
```
- **LRU eviction on updates** - Check memory limits when updating existing keys (not just new entries), as the new value may be larger.

### Core Data Entities

- **Conversation**: `participantHash` (lookup), `keyHash` (uniqueness), `archivedAt`
- **Message**: Email with labels, participants, attachments, `isNewsletter` flag, `localModifiedAt` (conflict detection)
- **Account**: User profile with email aliases (critical for participant filtering)
- **PendingAction**: Offline action queue with `status` (pending/processing/failed/completed/abandoned)
- **AbandonedSyncMessage**: Tracks message IDs that failed to sync for potential retry

### Logging

```swift
Log.info("message", category: .sync)
Log.error("message", category: .api, error: error)
```

## Key Patterns

### Concurrency

- **@MainActor** only on ViewModels with `@Published` properties. Pure services (GmailAPIClient, MessageFetcher) should NOT be @MainActor.
- **@MainActor on init only** - When a class needs MainActor singletons but methods can run anywhere, mark only `init` and `static let shared` as @MainActor
- **Heavy work off MainActor** - Image processing, PDF operations, file I/O, SQLite operations must use `Task.detached { }.value`
- **Sendable conformance** - Pure service classes with only `let` properties use `@unchecked Sendable`
- **Actor isolation** for thread-safe mutable state (TokenManager, PendingActionsManager, caches)
- **Swift 6 actor init pattern** - Cannot assign to actor-isolated properties in `init`. Use `Task { await self.setupMethod() }` where the setup method assigns the property:
```swift
actor MyCache {
    private var cleanupTask: Task<Void, Never>?

    private init() {
        Task { await self.startPeriodicCleanup() }  // Defer to actor context
    }

    private func startPeriodicCleanup() {
        cleanupTask = Task { ... }  // Now allowed - we're in actor context
    }
}
```
- **NotificationCenter in actors** - Store observer token, remove in `deinit`. Use `Task { @MainActor [weak self] in }` to register.
- **Task deduplication for callbacks** - When network or system callbacks spawn tasks, track pending tasks to prevent accumulation during rapid events (e.g., network flaps):
```swift
private var pendingProcessTask: Task<Void, Never>?

networkMonitor.onConnectivityChange = { [weak self] isConnected in
    Task { await self?.scheduleProcessing() }
}

private func scheduleProcessing() {
    guard pendingProcessTask == nil, !isProcessing else { return }
    pendingProcessTask = Task { [weak self] in
        await self?.processAllPendingActions()
        await self?.clearPendingTask()
    }
}
```
- **Core Data threading** - Use `viewContext.perform { }` or `coreDataStack.newBackgroundContext()` - never synchronous fetches on MainActor
- **FetchedResults not thread-safe** - SwiftUI's `@FetchRequest` results are MainActor-bound. Collect needed data (IDs, values) on MainActor before passing to `Task.detached`
- **Async batch operations** - `saveContextWithRetry` is async; perform Core Data work in `context.perform { }`, save/sleep outside
- **Typed accessors** in `/Services/Models/` per-entity extensions (avoid `value(forKey:)`)
- **Extensions for code organization** - Large actors/structs split into extensions in separate files. Properties must be `internal` (not `private`) for extensions to access.
- **Nested ObservableObject forwarding** - Forward `objectWillChange` via Combine subscriptions when composing ObservableObjects
- User's aliases must be excluded from `participantHash` - load from Account entity if not in memory

### Gmail System Label IDs

Gmail API uses **singular** label IDs for system labels. Always use these exact IDs:
- `"INBOX"` - Inbox messages
- `"SENT"` - Sent messages
- `"DRAFT"` - Draft messages (NOT "DRAFTS")
- `"SPAM"` - Spam messages
- `"TRASH"` - Deleted messages
- `"UNREAD"` - Unread flag
- `"STARRED"` - Starred messages
- `"IMPORTANT"` - Important messages

**Critical:** Gmail API queries use lowercase (`-label:drafts`), but label IDs in responses are uppercase (`"DRAFT"`). The sync queries and Core Data predicates use different formats.

### Email Normalization (Gmail)

Gmail treats dots in the local part as insignificant: `firstname.lastname@gmail.com` and `firstnamelastname@gmail.com` are the same account. Use `EmailNormalizer.normalize()` for all email comparisons:

- Removes dots from Gmail local part
- Strips `+` suffixes (plus addressing)
- Normalizes `googlemail.com` → `gmail.com`
- Lowercases everything

**Critical usage points:**
- `ConversationIdentity.normalizedEmail()` - participant hash computation
- `ContactsResolver` - contact lookups and caching
- `ConversationFilterService` - Contacts vs Other filtering
- `PersonFactory` - Person entity lookups (callers must normalize)

### Conversation Visibility Logic

Conversations appear in the chat list based on `archivedAt == nil`. Archive state is managed by `ConversationRollupUpdater`:
- **INBOX messages** → Conversation visible (`archivedAt = nil`)
- **Sent-only conversations** (no replies yet) → Stay visible until manually archived
- **All INBOX labels removed** → Auto-archived (`archivedAt = Date()`)
- **New message arrives for archived conversation** → Auto un-archived by `ConversationCreationSerializer`

### Sync Utilities

The sync system uses shared utilities to eliminate code duplication:

**SyncTimeCalculator** - Centralized time calculations for sync operations:
```swift
// Build Gmail query with proper time window
let query = SyncTimeCalculator.buildSyncQuery(config: .initialSync)

// Get start time for different sync types
let startTime = SyncTimeCalculator.calculateStartTime(config: .historyRecovery)
let startDate = SyncTimeCalculator.calculateStartDate(config: .reconciliation)

// Available configs: .initialSync, .historyRecovery, .reconciliation
```

**MessageListPaginator** - Shared pagination for message list fetching:
```swift
// Fetch all message IDs with automatic pagination
let messageIds = try await MessageListPaginator.fetchAllMessageIds(
    query: query,
    using: messageFetcher
)

// Or fetch and process in one call
let result = try await MessageListPaginator.fetchAndProcess(
    query: query,
    messageFetcher: messageFetcher,
    progressHandler: { processed, total in ... },
    messageHandler: { message in ... }
)
```

**LabelOperationProcessor** - Unified processor for label additions/removals:
```swift
// Process label changes (add or remove)
let modifiedConversations = await LabelOperationProcessor.process(
    items: labelsAdded,      // or labelsRemoved
    operation: .add,          // or .remove
    in: context,
    syncStartTime: syncStartTime
)
```

### Sync Optimization

**Differential rollup updates** - Instead of updating all conversation rollups after sync (O(n×m) operation), only modified conversations are updated:
1. `ModificationTracker.shared` (actor) is the single source of truth for tracking modified conversations
2. Both `MessagePersister` and `HistoryProcessor` delegate tracking to `ModificationTracker.shared`
3. After sync, call `ModificationTracker.shared.getAndClearModifiedConversations()` to get the set
4. Pass to `conversationManager.updateRollupsForModifiedConversations(conversationIDs:in:)`

This is used in `InitialSyncOrchestrator`, `IncrementalSyncOrchestrator`, `ConversationUpdatePhase`, and `SyncEngine.updateConversationRollups()`.

**Batch fetching in label operations** - `LabelOperationProcessor` uses batch Core Data queries:
- Collect all message IDs and label IDs upfront before processing
- Single batch fetch with `NSPredicate(format: "id IN %@", allMessageIds)`
- Prefetch relationships: `["labels", "conversation"]`
- Create dictionary lookup for O(1) access during processing

**Parallel Gmail API calls** - `SyncReconciliation.reconcileLabelStates()` uses bounded concurrency:
- `withTaskGroup` for concurrent API requests
- Chunked into batches of 10 concurrent requests (`maxConcurrentGmailRequests`)
- Results collected into dictionary, then batch-processed against local state

**Set-based message ID deduplication** - `HistoryCollectionPhase` and `HistoryProcessor.extractNewMessageIds()` use `Set<String>` to prevent duplicate message fetches across history pages.

**Chronological message persistence** - `MessageFetcher.fetchBatch()` fetches messages in parallel for performance, but collects all results and sorts by `internalDate` before calling the persistence callback. This ensures messages are persisted in chronological order, preventing temporary out-of-order display in the UI during sync.

**Bounded message fetch concurrency** - `MessageFetcher.fetchBatch()` limits concurrent API requests to `SyncConfig.maxConcurrentMessageFetches` (default 15) to prevent resource exhaustion with large mailboxes. Uses iterator pattern with TaskGroup to maintain constant concurrency.

**Sync phase cancellation** - All sync phases should check `try Task.checkCancellation()` in loops to respect sync cancellation requests. `LabelProcessingPhase` checks cancellation between processing each history record.

**History page limits** - `HistoryCollectionPhase` limits to 50 pages maximum (`maxHistoryPages`) to prevent OOM on large mailboxes with thousands of changes. If exceeded, partial sync continues and next sync catches remaining.

**Batch persistence for abandoned messages** - `SyncFailureTracker.persistAbandonedMessages()` uses batch fetch with dictionary lookup instead of N+1 queries when persisting failed message IDs.

### Sync Conflict Resolution

**Local modification tracking** - When users take actions locally (mark read/unread, archive), `message.localModifiedAt` is set to prevent server sync from overwriting:
- `MessageActions` sets `localModifiedAt = Date()` on all local modifications
- `HistoryProcessor.hasConflict()` checks this timestamp during sync
- Local changes are protected for 30 minutes (`maxLocalModificationAge = 1800s`)
- After 30 minutes, server updates are allowed (prevents indefinite blocking)

**Reconciliation** - Catches label drift between Gmail and local state:
- Runs automatically when history API returns changes
- Also runs periodically (every hour) even if history is empty (`SyncConfig.reconciliationInterval`)
- Covers 24-hour window (`SyncReconciliation.reconcileLabelStates`)

### Abandoned Actions & Messages

**Pending action failures** - When actions fail permanently (5 retries exceeded):
- Status changed to `"abandoned"` (distinct from `"failed"`)
- Notification posted: `.pendingActionFailed`
- Query via `PendingActionsManager.abandonedActionCount()`, `fetchAbandonedActions()`
- Retry via `retryAbandonedAction()`, `retryAllAbandonedActions()`
- Dismiss via `dismissAbandonedAction()`, `dismissAllAbandonedActions()`

**Abandoned sync messages** - When message fetches fail repeatedly and historyId must advance:
- Message IDs persisted to `AbandonedSyncMessage` Core Data entity
- Notification posted: `.syncMessagesAbandoned` with `userInfo["count"]`
- Query via `SyncFailureTracker.abandonedSyncMessageCount()`, `fetchAbandonedSyncMessageIds()`
- Clear via `removeAbandonedSyncMessage()`, `clearAllAbandonedSyncMessages()`

### Core Data Performance

**Always set fetchBatchSize** - All fetch requests that may return large result sets MUST set `fetchBatchSize` to prevent loading all objects into memory at once:
```swift
let request = Conversation.fetchRequest()
request.fetchBatchSize = 50  // Required for large result sets
```

**Batch fetch instead of N+1 loops** - Never fetch individual objects in a loop. Use `IN` predicate:
```swift
// Avoid (N+1 queries):
for messageId in messageIds {
    let request = Message.fetchRequest()
    request.predicate = NSPredicate(format: "id == %@", messageId)
    if let message = try context.fetch(request).first { ... }
}

// Prefer (single query):
let request = Message.fetchRequest()
request.predicate = NSPredicate(format: "id IN %@", messageIds)
request.fetchBatchSize = 100
let messages = try context.fetch(request)
```

**Prefetching relationships** - When accessing `Conversation.participantsArray` in loops, prefetch relationships to avoid N+1 queries:
```swift
request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
```

`ConversationRollupUpdater` prefetches `["messages", "messages.labels", "participants", "participants.person"]` in all batch methods to avoid N+1 queries when computing rollups.

**Composite indexes** - `CoreDataIndexes.swift` creates SQLite indexes for common query patterns. The conversation list uses `idx_conversation_visible_sorted` for `hidden == NO AND archivedAt == nil ORDER BY lastMessageDate DESC`.

### Batch Operations for Instant UI

When performing bulk actions (e.g., "select all and archive"), use batch methods for instant UI response:

```swift
// Avoid: Sequential loop (slow - N saves, N pending actions)
for conversation in selectedConversations {
    await messageActions.archiveConversation(conversation: conversation)
}

// Prefer: Single batch operation (instant - 1 save, 1 pending action)
await messageActions.archiveConversations(conversations: selectedConversations)
```

**Batch archive pattern** (`MessageActions.archiveConversations`):
1. Fetch shared resources once (e.g., INBOX label)
2. Loop through all items in memory, updating state
3. Single `saveIfNeeded()` for all Core Data changes
4. Single pending action with combined payload (`messageIds: [all IDs]`)

The existing `archiveConversation` action type handles batch message IDs via `apiClient.batchModify()`.

### Error Handling

Prefer explicit error logging over silent `try?`:
```swift
// Avoid:
let value = try? loadString(for: .key)

// Prefer:
do {
    let value = try loadString(for: .key)
} catch {
    Log.warning("Failed to load value", category: .auth)
}
```

**File system operations** - Use `FileSystemErrorHandler` instead of silent `try?`:
```swift
// Avoid:
try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
try? fileManager.removeItem(at: url)
let data = try? Data(contentsOf: url)

// Prefer:
FileSystemErrorHandler.createDirectory(at: url, category: .attachment)
FileSystemErrorHandler.removeItem(at: url, category: .attachment)
let data = FileSystemErrorHandler.loadData(from: url, category: .attachment)
```

**Core Data saves** - Use `saveOrLog` instead of `try? context.save()` inside `context.perform {}` blocks:
```swift
// Avoid:
try? context.save()

// Prefer:
context.saveOrLog(operation: "update message read status")
```

### Rate Limiting

`GmailAPIClient.performRequestWithRetry()` respects the `Retry-After` HTTP header on 429 responses. Falls back to exponential backoff if header not present.

### Observing Core Data Changes for Async Operations

When a view displays data that will be populated asynchronously (e.g., attachment downloads), use `onChange` to reload when the property becomes available:

```swift
// Problem: onAppear runs once with nil values, download completes later but view doesn't update
.onAppear {
    thumbnailLoader.load(attachmentId: attachment.id, previewPath: attachment.previewURL)  // previewURL is nil
    if attachment.state == .queued {
        Task { await downloader.downloadAttachmentIfNeeded(for: attachment) }  // Sets previewURL later
    }
}

// Solution: Add onChange to reload when the property becomes available
.onChange(of: attachment.previewURL) { oldValue, newValue in
    if newValue != nil && thumbnailLoader.image == nil {
        thumbnailLoader.reset()
        thumbnailLoader.load(attachmentId: attachment.id, previewPath: newValue)
    }
}
```

This pattern is used in:
- `ImageAttachmentBubble` - Observes `previewURL` to show inline image after download
- `AttachmentGridItem` - Observes `localURL` to show grid thumbnail after download

**Why it works:** Core Data entities (NSManagedObject) are observable. When `AttachmentDownloader` saves the background context, changes merge to the view context and trigger `onChange`.

### SwiftUI Singletons

Use `@EnvironmentObject` for shared singletons injected at app root, not `@StateObject`:
```swift
// Avoid:
@StateObject private var authSession = AuthSession.shared

// Prefer:
@EnvironmentObject private var authSession: AuthSession
```

### Dependency Injection

Use `Dependencies` container for testability. Actor instances are stored as private properties and exposed via nonisolated getters:
```swift
// In ViewModels/Services:
init(deps: Dependencies = .shared) {
    self.coreDataStack = deps.coreDataStack
    self.messageActions = deps.makeMessageActions()
}

// In tests:
let testDeps = Dependencies(
    coreDataStack: testStack,
    pendingActionsManager: testManager,
    // ... other test doubles
)
let viewModel = ChatViewModel(deps: testDeps)
```

### Configuration Constants

Use centralized config structs from `Constants.swift` instead of magic numbers:
- **CacheConfig** - Cache sizes (`textCacheSize`, `photoCacheSize`) and TTLs (`photoCacheTTL`, `diskImageCacheTTL`)
- **SyncConfig** - Batch sizes, timeouts, retry limits, time buffer constants:
  - `timestampBufferSeconds` (300) - 5-min buffer for sync timestamps
  - `recoveryBufferSeconds` (600) - 10-min buffer for recovery operations
  - `maxLocalModificationAge` (1800) - 30-min protection for local changes
  - `maxReconciliationWindow` (86400) - 24-hour cap for reconciliation
  - `initialSyncFallbackWindow` - 30-day fallback for initial sync
  - `recoveryFallbackWindow` - 7-day fallback for history recovery
- **NetworkConfig** - Request timeouts, retry delays
- **CoreDataConfig** - Fetch batch sizes, save retry limits

**GoogleConfig validation** - Check configuration at runtime:
```swift
if GoogleConfig.isConfigured {
    // All required keys present
} else {
    let missing = GoogleConfig.missingKeys  // ["GOOGLE_CLIENT_ID", ...]
}
```

### Fresh Install Detection

`FreshInstallHandler` detects app reinstalls by comparing UserDefaults (cleared on uninstall) vs Keychain (persists). On fresh install:
1. Clears stale keychain credentials
2. Signs out from Google
3. Clears Core Data and caches
4. Generates new installation ID

### Testing

Test infrastructure in `esc-chatmailTests/TestSupport/`:

- **TestCoreDataStack** - In-memory Core Data for isolated, fast tests
- **TestDependencies** - Mock dependency container
- **Builders** - Fluent test data builders:
  - `ConversationBuilder` - `.withDisplayName("Test").visible().setPinned().build(in: context)`
  - `MessageBuilder` - `.withSubject("Test").unread().inConversation(conv).build(in: context)`
  - `PendingActionBuilder` - `.markAsRead().forMessage("id").pending().build(in: context)`
- **Mocks** - `MockTokenManager`, `MockKeychainService`
- **XCTestCase+Async** - `waitForAsync { }`, `waitForAsyncResult { }`, `assertAsyncThrows { }`

**Test suites:**
- `DisplayNameFormatterTests` - Name formatting logic
- `ConversationMergerTests` - Duplicate detection and merge logic
- `PendingActionsManagerTests` - Offline action queue patterns
- `SendErrorTests` - Send error handling
- `GoogleConfigTests` - Configuration validation
- `LRUCacheActorTests` - LRU cache eviction, TTL, memory limits
- `PlainTextQuoteRemoverTests` - Email quote and signature removal
- `HTMLQuoteRemoverTests` - HTML-specific quote patterns
- `HTMLSanitizerServiceTests` - XSS prevention, script/tracking removal
