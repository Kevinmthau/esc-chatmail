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
- **ConversationCreationSerializer** - Actor preventing duplicate conversations during concurrent processing (throws `ConversationCreationError` on failure)
- **ContactsResolver** - Actor for contact lookup with caching
- **PendingActionsManager** - Actor-based offline action queue with retry logic
- **ProfilePhotoResolver** - Resolves profile photos from contacts and cache
- **MessagePersister** - Tracks modified conversations during sync for differential rollup updates

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
- **NotificationCenter in actors** - Store observer token, remove in `deinit`. Use `Task { @MainActor [weak self] in }` to register.
- **Core Data threading** - Use `viewContext.perform { }` or `coreDataStack.newBackgroundContext()` - never synchronous fetches on MainActor
- **Async batch operations** - `saveContextWithRetry` is async; perform Core Data work in `context.perform { }`, save/sleep outside
- **Typed accessors** in `/Services/Models/` per-entity extensions (avoid `value(forKey:)`)
- **Extensions for code organization** - Large actors/structs split into extensions in separate files. Properties must be `internal` (not `private`) for extensions to access.
- **Nested ObservableObject forwarding** - Forward `objectWillChange` via Combine subscriptions when composing ObservableObjects
- User's aliases must be excluded from `participantHash` - load from Account entity if not in memory

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

### Sync Optimization

**Differential rollup updates** - Instead of updating all conversation rollups after sync (O(n×m) operation), only modified conversations are updated:
1. `MessagePersister.trackModifiedConversation()` records conversation IDs during message save
2. After sync, call `messagePersister.getAndClearModifiedConversations()` to get the set
3. Pass to `conversationManager.updateRollupsForModifiedConversations(conversationIDs:in:)`

This is used in `InitialSyncOrchestrator`, `IncrementalSyncOrchestrator`, and `SyncEngine.updateConversationRollups()`.

### Core Data Performance

**Prefetching relationships** - When accessing `Conversation.participantsArray` in loops, prefetch relationships to avoid N+1 queries:
```swift
request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
```

**Composite indexes** - `CoreDataIndexes.swift` creates SQLite indexes for common query patterns. The conversation list uses `idx_conversation_visible_sorted` for `hidden == NO AND archivedAt == nil ORDER BY lastMessageDate DESC`.

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

### SwiftUI Singletons

Use `@EnvironmentObject` for shared singletons injected at app root, not `@StateObject`:
```swift
// Avoid:
@StateObject private var authSession = AuthSession.shared

// Prefer:
@EnvironmentObject private var authSession: AuthSession
```
