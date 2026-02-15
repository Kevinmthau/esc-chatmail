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
- Commit messages must be detailed and action-led, and should include:
  - what changed,
  - why it changed,
  - behavior impact/scope,
  - tests run (when applicable).
- Preferred format: concise subject line + explanatory body covering the items above.
- PRs should include: a concise summary, tests run, and screenshots for UI changes.
- Link related issues when applicable.

## Security & Configuration Notes
- OAuth/secret values live in xcconfig files under `esc-chatmail/Configuration/` and may be excluded from git.
- Use `Configuration/SECURITY_SETUP.md` and the `Config.xcconfig.template` when setting up locally.
- Git worktrees (including Codex worktrees under `~/.codex/worktrees/...`) do not share gitignored files. Before building/running in a new worktree, ensure `esc-chatmail/Configuration/Debug.xcconfig` and `esc-chatmail/Configuration/Release.xcconfig` exist; if they are missing, sync them from any worktree that already has them:

```bash
# Copy Debug.xcconfig + Release.xcconfig from the first worktree that has them into all worktrees.
set -euo pipefail

SRC=""
for wt in $(git worktree list --porcelain | awk '$1=="worktree"{print $2}'); do
  if [ -f "$wt/esc-chatmail/Configuration/Debug.xcconfig" ] && [ -f "$wt/esc-chatmail/Configuration/Release.xcconfig" ]; then
    SRC="$wt/esc-chatmail/Configuration"
    break
  fi
done

if [ -z "$SRC" ]; then
  echo "No worktree has Debug.xcconfig/Release.xcconfig. Create them from esc-chatmail/Configuration/Config.xcconfig.template first."
  exit 1
fi

for wt in $(git worktree list --porcelain | awk '$1=="worktree"{print $2}'); do
  mkdir -p "$wt/esc-chatmail/Configuration"
  cp -f "$SRC/Debug.xcconfig" "$wt/esc-chatmail/Configuration/Debug.xcconfig"
  cp -f "$SRC/Release.xcconfig" "$wt/esc-chatmail/Configuration/Release.xcconfig"
done
```

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

### Message Cleanup & Chat Bubbles
Chat bubble text should be conservative: prefer leaving extra quoted/footer content over deleting user-authored text.

Bubble/plain-text processing pipeline (see `Views/Chat/MessageContentView.swift` and `Services/TextProcessing/`):
1) `RawEmailSourceSanitizer.extractDisplayText(...)` (strip RFC822/MIME scaffolding when needed)
2) `HTMLEntityDecoder.decode(...)`
3) `TextProcessing.unwrapEmailLineBreaks(...)`
4) `PlainTextQuoteRemover.extractQuotes(...)` (quote boundary detection + `PlainTextSignatureRemover`)
5) `TextProcessing.formatSignOffLineBreaks(...)`

Notes:
- Keep the "immediate fallback" and "background cached" processing paths unified. If you change quote/signature removal, make sure both paths use the same APIs (typically `PlainTextQuoteRemover.extractQuotes`).
- Do not use `TextSnippetCreator` for chat bubbles; it condenses whitespace/newlines and is intended for preview snippets.
- Signature stripping must not treat phone numbers inside body sentences (e.g. "call me at 415-...") as standalone contact blocks. Only treat phone numbers as signature contact info when the line is primarily a phone line or has explicit prefixes (`T:`, `M:`, etc).

### Newsletter Detection & Preview Routing
- Newsletter classification is scored in `Services/MessageProcessor.swift` (`calculateNewsletterScore(...)`) and stored as `Message.isNewsletter`.
- Chat rendering decisions (HTML preview vs chat bubble) live in `Views/Chat/MessageDisplayPolicy.swift`.
- Rich transactional/marketing HTML can show preview cards even in one-to-one conversations; outgoing messages and `Re:` reply threads stay as plain chat bubbles.
- For false positives (personal mail treated as newsletter), adjust scoring/signals and add a golden corpus `newsletterDetectionCases` fixture.

### Golden Message Corpus (Regression Fixtures)
- Fixture: `esc-chatmailTests/TestSupport/Fixtures/golden_message_corpus.json`
- Harness: `GoldenCorpusReplayTests` in `esc-chatmailTests/MessageProcessorTests.swift`
- Run: `bash Scripts/run-tests.sh -only-testing 'esc-chatmailTests/GoldenCorpusReplayTests'`

Workflow for cleanup/policy regressions:
1) Add a failing real-world sample to the corpus (and a focused unit test if the bug is in a helper).
2) Confirm the corpus test fails.
3) Fix the parser/policy logic.
4) Re-run and keep the fixture permanently.

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
