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
  /Caching/           - LRUCacheActor, DiskImageCache, EnhancedImageCache, ImageRequestManager, ConversationPreloader
  /Concurrency/       - TaskCoordinator (generic actor for deduplicating concurrent operations)
  /CoreData/          - CoreDataStack, error handling (CoreDataErrorClassifier, CoreDataRecoveryHandler, CoreDataBackupManager)
  /Retry/             - ExponentialBackoff (reusable retry utilities)
  /Security/          - TokenManager, KeychainService, GoogleTokenRefresher
  /Sync/              - SyncEngine, orchestrators, persisters (MessagePersister, LabelPersister, AccountPersister)
    /Phases/          - SyncPhase protocol and composable phase implementations
  /Compose/           - RecipientManager, ContactAutocompleteService, ReplyMetadataBuilder, MessageFormatBuilder
  /VirtualScroll/     - VirtualScrollConfiguration, MessageWindow
  /Background/        - BackgroundSyncManager (BGTaskScheduler)
  /HTMLSanitization/  - Security pipeline for email HTML (URL/CSS sanitization, tracking removal)
/Views/
  /Chat/              - ChatView, MessageBubble (with style config), MessageContentView, BubbleAvatarView, MessageBubbleStyle
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

- **`/Services/Caching/`** - Image caching (DiskImageCache, EnhancedImageCache), request deduplication (ImageRequestManager), conversation preloading (ConversationPreloader)
- **`/Services/Concurrency/`** - TaskCoordinator actor for preventing duplicate concurrent operations (used by TokenManager)
- **`/Services/Retry/`** - ExponentialBackoff and ExponentialBackoffActor for retry logic with jitter
- **`/Services/CoreData/`** - CoreDataStack with extracted error classification (CoreDataErrorClassifier), backup management (CoreDataBackupManager), and recovery handling (CoreDataRecoveryHandler)
- **`/Services/Security/`** - TokenManager (uses TaskCoordinator + ExponentialBackoffActor), GoogleTokenRefresher (isolated OAuth logic)
- **`/Services/Sync/`** - SyncEngine orchestrates InitialSyncOrchestrator (full sync) and IncrementalSyncOrchestrator (delta sync via History API)
- **`/Services/Sync/Phases/`** - Composable SyncPhase protocol with phases: HistoryCollection, MessageFetch, LabelProcessing, Reconciliation, ConversationUpdate
- **`/Services/Compose/`** - Extracted compose services: RecipientManager, ContactAutocompleteService, ReplyMetadataBuilder, MessageFormatBuilder
- **`/Services/Background/`** - BackgroundSyncManager handles iOS background tasks (BGTaskScheduler)
- **ConversationManager** - Groups messages by `participantHash` (normalized emails excluding user's aliases)
- **ConversationCreationSerializer** - Actor preventing duplicate conversations during concurrent processing
- **PendingActionsManager** - Actor-based offline action queue with retry logic

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
- **AttachmentCache** - Thumbnails (500/50MB) and full images (20/100MB)
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

- **@MainActor** on ViewModels and UI services
- **Actor isolation** for thread-safe state (TokenManager, PendingActionsManager, ConversationCreationSerializer, ProcessedTextCache, DiskImageCache, EnhancedImageCache)
- **Background contexts** for Core Data operations
- **Typed accessors** in `/Services/Models+Extensions.swift` (avoid `value(forKey:)`)
- **Extensions for code organization** - MessagePersister uses extensions in separate files (LabelPersister.swift, AccountPersister.swift)
- **SyncPhase protocol** - Composable sync phases with typed Input/Output and progress reporting via SyncPhaseContext
- **Service composition** - ViewModels compose extracted services (e.g., ComposeViewModel uses RecipientManager, ContactAutocompleteService)
- **Nested ObservableObject forwarding** - When ViewModels compose child ObservableObjects, forward `objectWillChange` via Combine subscriptions (see ComposeViewModel)
- **Reusable utilities** - ExponentialBackoff for retry logic, TaskCoordinator for deduplication, CoreDataErrorClassifier for error handling
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
