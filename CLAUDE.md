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
```

## Architecture

iOS email client that syncs Gmail and presents emails as chat-style conversations.

```
Gmail API → SyncEngine → Core Data → SwiftUI Views
                ↓
        PendingActionsManager (offline queue) → Gmail API
```

### Directory Structure

```
/Services/
  /API/               - GmailAPIClient extensions: Messages, Labels, History, Attachments
  /Caching/           - LRUCacheActor, AttachmentCacheActor, DiskImageCache, EnhancedImageCache, ImageRequestManager, ConversationPreloader, ConversationCache extensions (+LRU, +TTL, +Memory, +Statistics)
  /Chat/              - ChatContactManager (contact lookup/updates for chat view)
  /Concurrency/       - TaskCoordinator, BackgroundWork (Task.detached utilities)
  /Contacts/          - ContactMatch, ContactSearchService, ContactPersistenceService (split from ContactsResolver)
  /CoreData/          - CoreDataStack, FetchRequestBuilder, NSManagedObjectContext+Perform, error handling
    /BatchOperations/ - BatchConfiguration, MessageBatchOperations, ConversationBatchOperations
  /Compose/           - RecipientManager, ContactAutocompleteService, ReplyMetadataBuilder, MessageFormatBuilder, ComposeSendOrchestrator
    /MimeBuilder/     - MimeBuilder split into extensions: +Headers, +SimpleMessage, +MultipartMessage, +Reply
  /DatabaseMaintenance/ - DatabaseMaintenanceService split: core, Cleanup, SQLite, Stats
  /ErrorHandling/     - FileSystemError, FileSystemErrorClassifier (error classification and recovery actions)
  /Fetcher/           - ParallelMessageFetcher support: FetchConfiguration, FetchPriority, FetchTask, FetchMetrics, AdaptiveMessageFetcher
  /HTMLSanitization/  - Security pipeline for email HTML (URL/CSS sanitization, tracking removal)
  /Logging/           - Log, LogLevel, LogCategory, LoggerConfiguration, ScopedLogger
  /Models/            - Per-entity Core Data extensions (Account, Message, Conversation, etc.)
  /PendingActions/    - PendingActionsManagerProtocol, PendingActionProcessor, PendingActionQueries (split from PendingActionsManager)
  /Retry/             - ExponentialBackoff, RetryExecutor (reusable retry utilities)
  /Security/          - TokenManager (+Refresh, +AsyncUtilities), KeychainService (+Convenience, +Installation), GoogleTokenRefresher
  /Send/              - GmailSendService extensions: Models, Attachments, OptimisticUpdates
  /Sync/              - SyncEngine, orchestrators, persisters; HistoryProcessor extensions (LabelOperations, MessageDeletions)
    /Cleanup/         - DataCleanupService extensions: Migration, DuplicateRemoval, EntityCleanup
    /Persistence/     - MessagePersister extensions: Updates, Creation, Participants, Helpers
    /Phases/          - SyncPhase protocol and composable phase implementations
  /TextProcessing/    - EmailTextProcessor support: HTMLEntityDecoder, HTMLQuoteRemover, PlainTextQuoteRemover, TextSnippetCreator
  /VirtualScroll/     - VirtualScrollConfiguration, MessageWindow
  /Background/        - BackgroundSyncManager, BackgroundTaskRegistry, BackgroundTaskConfiguration (BGTaskScheduler)
  WebKitPrewarmer.swift - Prewarms WKWebView for faster newsletter rendering
/Views/
  /Chat/              - ChatView, MessageBubble (with style config), MessageContentView, BubbleAvatarView, MessageBubbleStyle, MessageContextMenuPreview
  /Compose/           - ComposeView, RecipientChip, ComposeAttachmentThumbnail
  /Components/
    /Attachments/     - AttachmentGridView, ImageAttachmentBubble, PDFAttachmentCard, etc.
    /EmailContent/    - MiniEmailWebView, HTMLPreviewWebView, HTMLFullWebView
    /Skeletons/       - MessageSkeletonView, ConversationSkeletonView
    AvatarView, UnreadBadge, AttachmentIndicator, ViewContentButton, MessageMetadata
/ViewModels/          - @MainActor view models (VirtualScrollState, ConversationListState, ComposeViewModel, etc.)
/Models/              - Core Data entity classes
```

### Key Components

- **`/Services/Caching/`** - Image caching (DiskImageCache, EnhancedImageCache), request deduplication (ImageRequestManager), conversation preloading (ConversationPreloader), ConversationCache split (+LRU eviction, +TTL cleanup, +Memory warning handling, +Statistics)
- **`/Services/Concurrency/`** - TaskCoordinator actor for preventing duplicate concurrent operations, BackgroundWork for Task.detached utilities
- **`/Services/Contacts/`** - Contact lookup split into: ContactMatch (protocol/types), ContactSearchService (CNContact search), ContactPersistenceService (Core Data updates)
- **`/Services/CoreData/`** - CoreDataStack, FetchRequestBuilder (chainable query builder), NSManagedObjectContext+Perform (async fetch helpers), error classification
- **`/Services/CoreData/BatchOperations/`** - Batch operations split into: BatchConfiguration (types/config), MessageBatchOperations, ConversationBatchOperations
- **`/Services/API/`** - GmailAPIClient split into extensions: Messages (list/get/modify), Labels (profile/aliases), History, Attachments
- **`/Services/Send/`** - GmailSendService split into extensions: Models (SendResult/SendError), Attachments, OptimisticUpdates
- **`/Services/Sync/Cleanup/`** - DataCleanupService split into extensions: Migration, DuplicateRemoval, EntityCleanup
- **`/Services/Sync/Persistence/`** - MessagePersister split into extensions: Updates, Creation, Participants, Helpers
- **`/Services/Logging/`** - Logger split into: Log (main interface), LogLevel, LogCategory, LoggerConfiguration, ScopedLogger
- **`/Services/PendingActions/`** - Offline queue split into: PendingActionsManagerProtocol, PendingActionProcessor (execution/retry), PendingActionQueries (count/cancel)
- **`/Services/ErrorHandling/`** - FileSystemError (typed errors), FileSystemErrorClassifier (maps NSError codes to RecoveryAction)
- **`/Services/Fetcher/`** - Supporting types for ParallelMessageFetcher: FetchConfiguration, FetchPriority, FetchTask, FetchMetrics, AdaptiveMessageFetcher (UI wrapper with auto-optimization)
- **`/Services/Retry/`** - ExponentialBackoff, ExponentialBackoffActor, RetryExecutor (reusable retry with configurable strategies)
- **`/Services/Security/`** - TokenManager split (+Refresh for retry logic, +AsyncUtilities for withValidToken/withTokenRetry), KeychainService split (+Convenience for String/Codable helpers, +Installation for installation ID management), GoogleTokenRefresher (isolated OAuth logic)
- **`/Services/Sync/`** - SyncEngine orchestrates InitialSyncOrchestrator (full sync) and IncrementalSyncOrchestrator (delta sync via History API)
- **`/Services/Sync/Phases/`** - Composable SyncPhase protocol with phases: HistoryCollection, MessageFetch, LabelProcessing, Reconciliation, ConversationUpdate
- **`/Services/TextProcessing/`** - Email text extraction: HTMLEntityDecoder (lookup table), HTMLQuoteRemover, PlainTextQuoteRemover, TextSnippetCreator
- **`/Services/Compose/`** - Extracted compose services: RecipientManager, ContactAutocompleteService, ReplyMetadataBuilder, MessageFormatBuilder, ComposeSendOrchestrator
- **`/Services/Compose/MimeBuilder/`** - MIME message building split into: +Headers (formatting/encoding), +SimpleMessage, +MultipartMessage (attachments), +Reply (quote formatting)
- **`/Services/Chat/`** - ChatContactManager for contact lookup and updates in chat view
- **`/Services/Models/`** - Per-entity Core Data typed accessors (Account, Message, Conversation, Attachment, etc.)
- **`/Services/DatabaseMaintenance/`** - DatabaseMaintenanceService split into extensions: Cleanup, SQLite, Stats
- **`/Services/Background/`** - BackgroundSyncManager, BackgroundTaskRegistry (centralized task registration), BackgroundTaskConfiguration (task presets)
- **ConversationManager** - Groups messages by `participantHash` (normalized emails excluding user's aliases)
- **ConversationCreationSerializer** - Actor preventing duplicate conversations during concurrent processing
- **ContactsResolver** - Actor for contact lookup with caching (see `/Services/Contacts/`)
- **PendingActionsManager** - Actor-based offline action queue with retry logic (see `/Services/PendingActions/`)

### Message Display Logic

Messages render differently based on `message.isNewsletter` (detected during sync via Gmail labels, mailing list headers, sender patterns):
- **Newsletter emails** → `EmailContentSection` with `MiniEmailWebView` (scaled HTML preview)
- **Personal emails** → Chat bubbles with extracted plain text

### HTML Content Pipeline

```
HTMLContentLoader (cascading load: cache → storage URI → bodyText)
       ↓
HTMLSanitizerService (removes scripts, tracking, dangerous URLs)
       ↓
HTMLContentHandler (file storage in Documents/Messages/)
       ↓
MiniEmailWebView (50% scaled, non-interactive preview) or HTMLMessageView (full)
```

### Caching (Actor-based, LRU)

- **ProcessedTextCache** - Plain text extractions (500 items)
- **AttachmentCacheActor** - Thumbnails (500/50MB) and full images (20/100MB)
- **ConversationCache** - Preloaded conversations (100 items, 5min TTL), uses ConversationPreloader for background loading
- **EnhancedImageCache** - Two-tier cache (memory + disk) for remote images, uses ImageRequestManager for request deduplication
- **DiskImageCache** - Persistent disk cache for images (7-day TTL, 100MB limit)

### Core Data Entities

- **Conversation**: `participantHash` (lookup), `keyHash` (uniqueness), `archivedAt`
- **Message**: Email with labels, participants, attachments, `isNewsletter` flag
- **Account**: User profile with email aliases (critical for participant filtering)

### Logging

```swift
Log.info("message", category: .sync)
Log.error("message", category: .api, error: error)
```
Categories: sync, api, coreData, auth, ui, background, conversation

## Key Patterns

### Concurrency

- **@MainActor** only on ViewModels with `@Published` properties and classes with mutable UI state. Pure services (GmailAPIClient, MessageFetcher) should NOT be @MainActor.
- **@MainActor on init only** - When a class needs MainActor singletons (`TokenManager.shared`, `AuthSession.shared`) but methods can run anywhere, mark only `init` and `static let shared` as @MainActor
- **Heavy work off MainActor** - Image processing, PDF operations, file I/O, and SQLite operations (VACUUM, ANALYZE) must use `Task.detached { }.value`
- **Sendable conformance** - Pure service classes with only `let` properties use `@unchecked Sendable`
- **Actor isolation** for thread-safe mutable state (TokenManager, PendingActionsManager, ConversationCreationSerializer, ProcessedTextCache, DiskImageCache, EnhancedImageCache)
- **Core Data threading** - Use `viewContext.perform { }` or background context via `coreDataStack.newBackgroundContext()` - never synchronous fetches on MainActor
- **Typed accessors** in `/Services/Models/` (per-entity extension files, avoid `value(forKey:)`)
- **Extensions for code organization** - Large actors/structs split into extensions in separate files (ContactsResolver, PendingActionsManager, CoreDataBatchOperations). Main file keeps type definition + core logic, extensions in subdirectories handle specific concerns. Properties must be `internal` (not `private`) for extensions to access.
- **SyncPhase protocol** - Composable sync phases with typed Input/Output and progress reporting via SyncPhaseContext
- **Service composition** - ViewModels compose extracted services (e.g., ComposeViewModel uses RecipientManager, ContactAutocompleteService)
- **Nested ObservableObject forwarding** - When ViewModels compose child ObservableObjects, forward `objectWillChange` via Combine subscriptions (see ComposeViewModel)
- **Reusable utilities** - ExponentialBackoff/RetryExecutor for retry logic, TaskCoordinator for deduplication, CoreDataErrorClassifier/FileSystemErrorClassifier for error handling
- **Style configuration** - MessageBubble uses MessageBubbleStyle enum (`.standard` vs `.compact`) for different display modes
- User's aliases must be excluded from `participantHash` - load from Account entity if not in memory

### Conversation Visibility Logic

Conversations appear in the chat list based on `archivedAt == nil`. Archive state is managed by `ConversationRollupUpdater`:
- **INBOX messages** → Conversation visible (`archivedAt = nil`)
- **Sent-only conversations** (no replies yet) → Stay visible until manually archived
- **All INBOX labels removed** → Auto-archived (`archivedAt = Date()`)
- **New message arrives for archived conversation** → Auto un-archived by `ConversationCreationSerializer`

Gmail labels vs visibility:
- `INBOX` label → Message counts toward inbox visibility
- `SENT` label only → Sent-only conversation, kept visible
- No `INBOX` + has received messages → Archived
