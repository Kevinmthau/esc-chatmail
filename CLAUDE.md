# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is an iOS app using Xcode. Build with:
```bash
xcodebuild -scheme esc-chatmail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### Configuration Setup (Required)
Before building, set up OAuth credentials:
```bash
cd esc-chatmail/Configuration
cp Config.xcconfig.template Debug.xcconfig
cp Config.xcconfig.template Release.xcconfig
```
Edit both files with your Google OAuth credentials (client ID, API key, project details).

## Architecture Overview

ESC-Chatmail is an iOS email client that syncs with Gmail and presents emails as chat conversations.

### Core Data Flow
```
Gmail API → SyncEngine → Core Data → SwiftUI Views
                ↓
        PendingActionsManager (offline queue)
                ↓
            Gmail API (sync back)
```

### Sync Architecture

The sync system is decomposed into focused components:

**SyncEngine** (`/Services/Sync/SyncEngine.swift`)
- Lightweight orchestrator managing sync state and public API
- Delegates actual work to specialized orchestrators
- Manages `SyncUIState` for UI progress reporting

**InitialSyncOrchestrator** (`/Services/Sync/InitialSyncOrchestrator.swift`)
- Handles full sync when no historyId exists
- Phases: profile/aliases → labels → messages → conversation rollups

**IncrementalSyncOrchestrator** (`/Services/Sync/IncrementalSyncOrchestrator.swift`)
- Handles delta sync via Gmail History API
- Includes history recovery when historyId expires (falls back to full sync)

**SyncReconciliation** (`/Services/Sync/SyncReconciliation.swift`)
- Detects missed messages during sync
- Reconciles label states between Gmail and local data

**SyncFailureTracker** (`/Services/Sync/SyncFailureTracker.swift`)
- Tracks sync failures to determine when to advance historyId
- Prevents infinite retry loops on permanently failing messages

Supporting components: `MessageFetcher`, `MessagePersister`, `HistoryProcessor`, `BatchProcessor`

### Key Services

**ConversationManager** (`/Services/ConversationManager.swift`)
- Groups messages by `participantHash` (normalized participant emails)
- Archive-aware: new messages from archived contacts create fresh conversations
- Key fields: `archivedAt` (archive timestamp), `participantHash` (lookup key)

**PendingActionsManager** (`/Services/PendingActionsManager.swift`)
- Actor-based queue for offline-safe operations
- Persists actions to Core Data, retries with exponential backoff
- Actions: markRead, markUnread, archive, star, unstar

**CoreDataStack** (`/Services/CoreDataStack.swift`)
- Singleton managing persistent container
- Auto-migration enabled, error recovery with store reset

### Core Data Model

Key entities in `ESCChatmail.xcdatamodel`:
- **Conversation**: Chat thread grouped by participants (`participantHash`, `archivedAt`)
- **Message**: Individual email with labels, participants, attachments
- **PendingAction**: Queued user actions awaiting sync
- **Person**: Contact info cached from emails
- **Attachment**: Email attachments with download state tracking

### Utilities

**Logger** (`/Services/Logger.swift`)
- Structured logging with OSLog integration
- Categories: sync, api, coreData, auth, ui, attachment
- Usage: `Log.sync.info("message")` or `Log.api(endpoint:status:duration:)`

**NSManagedObjectContext+Fetch** (`/Services/NSManagedObjectContext+Fetch.swift`)
- Type-safe Core Data fetch helpers
- Generic methods: `fetchFirst`, `fetchAll`, `count`, `exists`
- Entity-specific: `fetchMessage(byId:)`, `fetchConversation(byKeyHash:)`, etc.
- Predicate builders: `MessagePredicates`, `ConversationPredicates`, `LabelPredicates`

**Models+Extensions** (`/Services/Models+Extensions.swift`)
- Typed accessors for Core Data entities (avoiding `value(forKey:)`)
- Includes computed properties like `Attachment.isReady`, `Attachment.isDownloaded`

### Authentication

- Google Sign-In SDK for OAuth
- **TokenManager**: Auto-refreshes tokens, thread-safe via actor
- **KeychainService**: Secure storage for tokens and credentials

### View Structure

- `ConversationListView`: Main inbox (filters by `archivedAt == nil`)
- `ChatView`: Conversation detail with messages
- `ComposeView` / `ChatReplyBar`: Message composition

## Key Patterns

- **@MainActor** on ViewModels and UI-modifying services
- **async/await** throughout for async operations
- **Actor isolation** for thread-safe state (PendingActionsManager, TokenManager)
- **Background contexts** for heavy Core Data operations
- Conversations use `participantHash` for lookup, `keyHash` for uniqueness
- **Typed accessors** preferred over `value(forKey:)` for Core Data properties
- **Structured logging** via `Log` singleton for consistent log output
