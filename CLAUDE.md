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

### Key Services

**SyncEngine** (`/Services/Sync/SyncEngine.swift`)
- Orchestrates all Gmail synchronization
- Delegates to: MessageFetcher, MessagePersister, HistoryProcessor, BatchProcessor
- Handles initial sync (full fetch) and incremental sync (Gmail History API)

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
