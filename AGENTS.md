# Repository Guidelines

## Project Structure & Module Organization
- `esc-chatmail/` contains the app source (Swift/SwiftUI), including `Services/`, `Views/`, `Models/`, and `Resources/`.
- `esc-chatmail.xcodeproj/` holds the Xcode project settings.
- `esc-chatmailTests/` contains unit tests; `esc-chatmailUITests/` contains UI tests.
- Configuration lives in `esc-chatmail/Configuration/` (see security notes below).

## Build, Test, and Development Commands
Use `xcodebuild` with the `esc-chatmail` scheme:
- Build (Debug, device): `xcodebuild build -scheme esc-chatmail -configuration Debug -sdk iphoneos`
- Build (Debug, simulator): `xcodebuild build -scheme esc-chatmail -configuration Debug -destination 'platform=iOS Simulator'`
- Build (Release): `xcodebuild build -scheme esc-chatmail -configuration Release -sdk iphoneos`
- Run all tests: `bash Scripts/run-tests.sh`
- Run a specific test: `bash Scripts/run-tests.sh -only-testing 'esc-chatmailTests/ConversationMergerTests'`
- Pre-submission checklist: `bash Scripts/testflight-checklist.sh`

## Coding Style & Naming Conventions
- Language: Swift/SwiftUI. Follow Swift API Design Guidelines.
- Indentation: 4 spaces; use trailing closures and explicit labels for clarity.
- Naming: `PascalCase` for types, `camelCase` for methods/vars, `UPPER_SNAKE_CASE` for constants only when conventional.
- File names generally match primary type (e.g., `MessageProcessor.swift`).

## Testing Guidelines
- Framework: XCTest.
- Test files live in `esc-chatmailTests/` and `esc-chatmailUITests/` with `*Tests.swift` naming.
- Prefer in-memory Core Data via `TestCoreDataStack` and builders (e.g., `MessageBuilder`).
- Add tests for behavior changes; keep unit tests fast and deterministic.

## Commit & Pull Request Guidelines
- Commit messages are short, imperative, and action-led (e.g., “Fix: Large HTML emails not showing thumbnail”, “Decode quoted-printable HTML bodies”).
- PRs should include: a concise summary, tests run, and screenshots for UI changes.
- Link related issues when applicable.

## Security & Configuration Notes
- OAuth/secret values live in xcconfig files under `esc-chatmail/Configuration/` and may be excluded from git.
- Use `Configuration/SECURITY_SETUP.md` and the `Config.xcconfig.template` when setting up locally.

## Architecture Overview
ESC Chatmail is a SwiftUI iOS email client that syncs with Gmail via the Gmail API and presents a conversation-first UI.

### Core Data Model
Core entities in `ESCChatmail.xcdatamodel`:
- **Account**: Gmail account with sync state (`historyId`).
- **Conversation**: Groups messages by participants; tracks inbox/archive/muted state.
- **Message**: Individual emails; body stored at `bodyStorageURI`.
- **Person**: Unique by email; linked via join tables.
- **Attachment**: File metadata with local caching state.
- **PendingAction**: Queued Gmail API operations (archive, star, spam, etc.).

### Dependency Injection
`Dependencies.swift` is the service container (`Dependencies.shared`). Tests inject mocks via `TestDependencies`.

### Concurrency Model
- **@MainActor**: ViewModels and UI classes.
- **Actors**: Thread-safe services such as `PendingActionsManager`, `PersonCache`, `AttachmentCacheActor`, `HistoryProcessor`, `TokenManager`.
- **@unchecked Sendable**: Mixed main/background services like `CoreDataStack`, `AuthSession`.
- Utilities in `Services/Concurrency/`: `ViewModelTaskManager`, `TaskCoordinator`, `BackgroundWork`.

### Sync Engine
Two orchestrators in `Services/Sync/`:
- **InitialSyncOrchestrator**: Full mailbox sync.
- **IncrementalSyncOrchestrator**: Delta sync via Gmail History API.
Key components: `MessageFetcher`, `MessagePersister`, `HistoryProcessor`.

### HTML Email Rendering
Pipeline:
1) `HTMLSanitizerService.sanitize()` removes scripts/forms/tracking pixels and preserves `<style>` tags.
2) `HTMLDisplayWrapper.wrapHTMLForDisplay()` adds viewport meta and minimal CSS.
3) `BaseEmailWebView` renders via `WKWebView`.

### View Architecture
ViewModels (`ChatViewModel`, `ConversationListViewModel`, `ComposeViewModel`) use `@Published`.
Views rely on `@FetchRequest` for reactive Core Data queries.

### Pending Actions System
User actions are stored as `PendingAction` entities:
1) `MessageActions` creates the record.
2) `PendingActionsManager` executes via `GmailActionExecutor`.
3) Success removes the record; failures retry with backoff.

### Error Handling
Error types: `APIError`, `CoreDataError`, `TokenManagerError`.
Retry behavior via `RetryExecutor`, `GmailAPIClient` rate-limit circuit breaker, and `MessageFetcher` retry classification.

### Logging
```swift
Log.info("Sync started", category: .sync)
Log.error("Failed", category: .api, error: error)
```
Categories include `.sync`, `.api`, `.coreData`, `.auth`, `.ui`, `.attachment`, `.message`, `.conversation`, `.background`.
