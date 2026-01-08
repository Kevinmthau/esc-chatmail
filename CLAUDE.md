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
  /API/               - GmailAPIClient (Messages, Labels, History, Attachments)
  /Caching/           - Image caching, conversation preloading, request deduplication
  /Compose/           - Email composition, MIME building, recipient management
  /Contacts/          - CNContact search, contact persistence
  /CoreData/          - CoreDataStack, FetchRequestBuilder, batch operations
  /Fetcher/           - ParallelMessageFetcher, adaptive fetch optimization
  /HTMLSanitization/  - Security pipeline for email HTML
  /Logging/           - Log categories: sync, api, coreData, auth, ui, background, conversation
  /PendingActions/    - Offline action queue with retry logic
  /Security/          - TokenManager, KeychainService, OAuth
  /Sync/              - SyncEngine, orchestrators, persisters, composable phases
  /TextProcessing/    - Email text extraction, quote removal
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
- **ConversationCreationSerializer** - Actor preventing duplicate conversations during concurrent processing
- **ContactsResolver** - Actor for contact lookup with caching
- **PendingActionsManager** - Actor-based offline action queue with retry logic
- **ProfilePhotoResolver** - Resolves profile photos from contacts and cache

### Message Display Logic

Messages render differently based on `message.isNewsletter` (detected via Gmail labels, mailing list headers, sender patterns):
- **Newsletter emails** → `MiniEmailWebView` (scaled HTML preview)
- **Personal emails** → Chat bubbles with extracted plain text

### HTML Content Pipeline

```
HTMLContentLoader (cache → storage URI → bodyText)
       ↓
HTMLSanitizerService (removes scripts, tracking, dangerous URLs)
       ↓
HTMLContentHandler (file storage in Documents/Messages/)
       ↓
MiniEmailWebView (50% scaled) or HTMLMessageView (full)
```

### Caching (Actor-based, LRU)

- **ProcessedTextCache** - Plain text extractions (500 items)
- **AttachmentCacheActor** - Thumbnails (500/50MB) and full images (20/100MB)
- **ConversationCache** - Preloaded conversations (100 items, 5min TTL)
- **EnhancedImageCache** - Two-tier cache (memory + disk) for remote images
- **DiskImageCache** - Persistent disk cache (7-day TTL, 100MB limit)

### Core Data Entities

- **Conversation**: `participantHash` (lookup), `keyHash` (uniqueness), `archivedAt`
- **Message**: Email with labels, participants, attachments, `isNewsletter` flag
- **Account**: User profile with email aliases (critical for participant filtering)

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
- **Core Data threading** - Use `viewContext.perform { }` or `coreDataStack.newBackgroundContext()` - never synchronous fetches on MainActor
- **Typed accessors** in `/Services/Models/` per-entity extensions (avoid `value(forKey:)`)
- **Extensions for code organization** - Large actors/structs split into extensions in separate files. Properties must be `internal` (not `private`) for extensions to access.
- **Nested ObservableObject forwarding** - Forward `objectWillChange` via Combine subscriptions when composing ObservableObjects
- User's aliases must be excluded from `participantHash` - load from Account entity if not in memory

### Conversation Visibility Logic

Conversations appear in the chat list based on `archivedAt == nil`. Archive state is managed by `ConversationRollupUpdater`:
- **INBOX messages** → Conversation visible (`archivedAt = nil`)
- **Sent-only conversations** (no replies yet) → Stay visible until manually archived
- **All INBOX labels removed** → Auto-archived (`archivedAt = Date()`)
- **New message arrives for archived conversation** → Auto un-archived by `ConversationCreationSerializer`
