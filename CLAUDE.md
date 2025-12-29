# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Simulator
xcodebuild -scheme esc-chatmail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Physical device
xcodebuild -scheme esc-chatmail -destination 'generic/platform=iOS' build
xcrun devicectl device install app --device <DEVICE_ID> path/to/esc-chatmail.app
```

## Architecture

iOS email client that syncs Gmail and presents emails as chat-style conversations.

```
Gmail API → SyncEngine → Core Data → SwiftUI Views
                ↓
        PendingActionsManager (offline queue) → Gmail API
```

### Key Components

- **`/Services/Sync/`** - SyncEngine orchestrates InitialSyncOrchestrator (full sync) and IncrementalSyncOrchestrator (delta sync via History API)
- **`/Services/Background/`** - BackgroundSyncManager handles iOS background tasks (BGTaskScheduler)
- **ConversationManager** - Groups messages by `participantHash` (normalized emails excluding user's aliases)
- **ConversationCreationSerializer** - Actor preventing duplicate conversations during concurrent processing
- **PendingActionsManager** - Actor-based offline action queue with retry logic

### Core Data Entities

- **Conversation**: `participantHash` (lookup), `keyHash` (uniqueness), `archivedAt`
- **Message**: Email with labels, participants, attachments
- **Account**: User profile with email aliases (critical for participant filtering)

### Logging

```swift
Log.info("message", category: .sync)
Log.error("message", category: .api, error: error)
```
Categories: sync, api, coreData, auth, ui, background, conversation

## Key Patterns

- **@MainActor** on ViewModels and UI services
- **Actor isolation** for thread-safe state (TokenManager, PendingActionsManager, ConversationCreationSerializer)
- **Background contexts** for Core Data operations
- **Typed accessors** in Models+Extensions.swift (avoid `value(forKey:)`)
- User's aliases must be excluded from `participantHash` - load from Account entity if not in memory
