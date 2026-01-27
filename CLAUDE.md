# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build (Debug)
xcodebuild build -scheme esc-chatmail -configuration Debug -sdk iphoneos

# Build for simulator (faster iteration)
xcodebuild build -scheme esc-chatmail -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16'

# Build (Release)
xcodebuild build -scheme esc-chatmail -configuration Release -sdk iphoneos

# Run all tests
xcodebuild test -scheme esc-chatmail -configuration Debug

# Run specific test file
xcodebuild test -scheme esc-chatmail -only-testing "esc-chatmailTests/ConversationMergerTests"

# Pre-submission checklist
bash Scripts/testflight-checklist.sh
```

## Architecture Overview

ESC Chatmail is a native iOS email client built with SwiftUI that syncs with Gmail via the Gmail API. It uses a conversation-based UI similar to messaging apps.

### Core Data Model

Six main entities in `ESCChatmail.xcdatamodel`:
- **Account** - Gmail account with sync state (historyId)
- **Conversation** - Groups messages by participants; has inbox/archive/muted state
- **Message** - Individual emails with body stored at bodyStorageURI
- **Person** - Unique by email; linked to conversations and messages via join tables
- **Attachment** - File metadata with local caching state
- **PendingAction** - Queued Gmail API operations (archive, star, spam, etc.)

### Dependency Injection

`Dependencies.swift` is the central service container (singleton at `Dependencies.shared`). All services are accessed through it, and tests inject mocks via `TestDependencies`.

### Concurrency Model

- **@MainActor** - All ViewModels and UI-related classes
- **Actor** - Background services requiring thread safety: `PendingActionsManager`, `PersonCache`, `AttachmentCacheActor`, `HistoryProcessor`, `TokenManager`
- **@unchecked Sendable** - Classes mixing main/background work: `CoreDataStack`, `AuthSession`

Concurrency utilities in `Services/Concurrency/`:
- **ViewModelTaskManager** - Cancels previous tasks before starting new ones (prevents orphaned tasks):
  ```swift
  taskManager.run("load") { await self?.performLoad() }
  ```
- **TaskCoordinator** - Actor preventing duplicate concurrent operations; returns existing in-flight task or creates new
- **BackgroundWork** - Cleaner API for `Task.detached` with logging support

### Sync Engine

The sync system in `Services/Sync/` uses two orchestrators:
1. **InitialSyncOrchestrator** - Full mailbox sync on first run
2. **IncrementalSyncOrchestrator** - Delta sync using Gmail History API

Key components: `MessageFetcher` (parallel retrieval), `MessagePersister` (Core Data storage), `HistoryProcessor` (processes changes).

Configuration in `Constants.swift`:
```swift
SyncConfig.messageBatchSize = 50
SyncConfig.maxConcurrentMessageFetches = 15
```

**Rate Limiting**: `GmailAPIClient` uses `RateLimitTracker` actor - circuit-breaks if >2 minutes cumulative backoff in 5-minute window.

### HTML Email Rendering

HTML emails are processed through:
1. `HTMLSanitizerService.sanitize()` - Removes scripts, forms, tracking pixels; **preserves `<style>` tags** for responsive layouts
2. `HTMLDisplayWrapper.wrapHTMLForDisplay()` - Adds viewport meta and minimal CSS
3. `BaseEmailWebView` - WKWebView wrapper with mobile content mode

### View Architecture

- **ViewModels** (`ChatViewModel`, `ConversationListViewModel`, `ComposeViewModel`) manage state with `@Published` properties
- **Services are composed** - e.g., `ConversationListViewModel` uses `SearchService`, `SelectionService`, `FilterService`
- Views use `@FetchRequest` for reactive Core Data queries

### Pending Actions System

User actions (archive, star, mark spam) are queued as `PendingAction` entities:
1. `MessageActions` creates the pending action
2. `PendingActionsManager` (Actor) executes via `GmailActionExecutor`
3. Success removes the action; failure triggers retry with backoff

### Error Handling

Centralized error classification in `UnifiedErrorClassifier`:
```swift
let classification = UnifiedErrorClassifier.classify(error)
switch classification.recoveryStrategy {
case .retry(let delay): // Retry with backoff
case .reauth:           // Re-authenticate user
case .abort:            // Stop and report
case .ignore:           // Log and continue
}
```

Error types: `APIError` (network/API), `CoreDataError` (persistence), `TokenManagerError` (auth tokens).

## Testing

Tests use in-memory Core Data via `TestCoreDataStack`. Test data is created with builders:
```swift
let message = MessageBuilder(context: testContext)
    .withSubject("Test")
    .withIsUnread(true)
    .build()
```

Available builders: `MessageBuilder`, `ConversationBuilder`, `PendingActionBuilder`, `PersonBuilder`

Mocks: `MockGmailAPIClient`, `MockKeychainService`, `MockTokenManager`, `MockNetworkMonitor`

Key test files: `ConversationMergerTests`, `PendingActionsManagerTests`, `HTMLSanitizerServiceTests`, `AttachmentDownloaderTests`

## Configuration

OAuth credentials are stored in xcconfig files (excluded from git):
- `Configuration/Debug.xcconfig`
- `Configuration/Release.xcconfig`

See `Configuration/SECURITY_SETUP.md` for setup instructions. Constants.swift reads values from Info.plist at runtime.

## Logging

```swift
Log.info("Sync started", category: .sync)
Log.error("Failed", category: .api, error: error)
```

Categories: `.sync`, `.api`, `.coreData`, `.auth`, `.ui`, `.attachment`, `.message`, `.conversation`, `.background`
