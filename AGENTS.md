# AGENTS.md

## Repo Overview

`esc-chatmail` is an iOS app that makes email feel like chat while preserving original-message fidelity where it matters.

Optimize for:
1. correctness
2. readability
3. minimal diffs
4. preserving the existing architecture unless there is a clear improvement

The repo uses:
- project: `esc-chatmail.xcodeproj`
- scheme: `esc-chatmail`
- deployment target: iOS `17.6`
- package dependencies resolved through SwiftPM in the project

## Git Workflow

- Work on `main` by default.
- Do not create new branches or worktrees for routine work unless the user explicitly asks for one.
- After branch-specific work is finished, return the repo to `main` unless the user asks to stay on a different branch.

## Default Build And Test Commands

Use the Xcode app toolchain explicitly. Plain `xcodebuild` will otherwise point at Command Line Tools on this machine.

Default simulator:
- `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1`
- `26.4` is not currently installed on this machine. If a command still references `26.4`, update it to `26.4.1`.

Exact build command:

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project esc-chatmail.xcodeproj \
  -scheme esc-chatmail \
  -configuration Debug \
  -destination "$DESTINATION"
```

Exact full test command:

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash Scripts/run-tests.sh
```

Narrow test pattern:

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash Scripts/run-tests.sh -only-testing 'esc-chatmailTests/<SuiteName>'
```

Participant and conversation-rollup adjacent suites:

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash Scripts/run-tests.sh \
  -only-testing 'esc-chatmailTests/ParticipantLoaderTests' \
  -only-testing 'esc-chatmailTests/ConversationRollupUpdaterTests'
```

Notes:
- `Scripts/run-tests.sh` uses scheme `esc-chatmail`, configuration `Debug`, and skips `PerformanceRegressionTests` unless `--performance` is passed.
- If `DESTINATION` is omitted, the script picks the first available iPhone simulator. Prefer setting it explicitly for reproducible Codex runs and to avoid failures when a previously documented runtime is no longer installed.

## Key Architecture Notes

App flow:
- `esc-chatmail/App/esc_chatmailApp.swift` boots the app, initializes `Dependencies.shared`, restores auth, waits for Core Data, and prewarms WebKit.
- `esc-chatmail/App/ContentView.swift` gates between sign-in and the main conversation UI.
- Main user surfaces live in:
  - `esc-chatmail/Views/Main/ConversationListView.swift`
  - `esc-chatmail/Views/Main/InboxListView.swift`
  - `esc-chatmail/Views/Chat/ChatView.swift`
  - `esc-chatmail/Views/Compose/ComposeView.swift`

State management:
- Shared app services come from `esc-chatmail/Services/Dependencies.swift` via `@EnvironmentObject`.
- Screen state is usually owned by `@StateObject` view models such as `ConversationListViewModel`, `ChatViewModel`, and `ComposeViewModel`.
- View models compose smaller services instead of pushing logic into the view layer.
- `ViewModelTaskManager` is the common pattern for cancelling or deduplicating async UI work.

Email rendering pipeline:
1. source selection and recovery: `HTMLContentLoader`, `HTMLContentHandler`, `HTMLContentRecoveryService`
2. sanitization and safety: `HTMLSanitizerService`, `HTMLRemoteImageAttachmentFallback`, URL/CSS sanitizers
3. presentation wrapping: `HTMLDisplayWrapper`
4. rendering surfaces:
   - full message: `HTMLMessageView` -> `HTMLWebView` -> `BaseEmailWebView(.fullInteractive)`
   - preview routing: `EmailContentSection`, `NewsletterPreviewBuilder`, `TransactionalPreviewBuilder`, `MiniEmailWebView`

Important rule:
- Do not mix preview-specific transformations into the full-message rendering path unless required.

## Repo-Specific Priorities

Be especially careful in:
- `esc-chatmail/Services/HTMLContentLoader.swift`
- `esc-chatmail/Services/HTMLSanitizerService.swift`
- `esc-chatmail/Services/HTMLSanitization/HTMLDisplayWrapper.swift`
- `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`
- preview rendering in chat/thread UI

Product principles:
- Full message view should prioritize fidelity to the original email.
- Chat previews may use derived representations optimized for speed, clarity, and stable layout.
- Do not degrade the full-message path to make previews easier.
- Prefer predictable UI over clever rendering tricks.
- Avoid fragile solutions that depend on scaling full email HTML documents in scrolling lists.

## Performance Guardrails

- Preserve Core Data batching and prefetching in inbox/chat list fetch requests.
- Treat `ChatMessagesView` scroll timing as delicate. It has staged initial, follow-up, and stabilization scroll tasks for a reason.
- Avoid introducing view-driven N+1 work when loaders/caches already exist.
- Repeated HTML sanitization, wrapping, or recovery passes are a regression risk.
- `MiniEmailWebView` height changes can destabilize scrolling. Keep preview heights predictable.
- `WebKitPrewarmer` exists because first-use `WKWebView` startup is expensive.

## UI And UX Guardrails

- Always inspect the relevant implementation before editing.
- Prefer small, reviewable diffs.
- Do not break visible behavior unless explicitly asked.
- Preserve navigation identity and sheet presentation behavior.
- Keep personal email in lightweight chat bubbles and reserve rich preview cards for the existing HTML-preview routing.
- Prefer native SwiftUI/UIKit presentation over brittle WebView hacks when possible.
- For email HTML changes, be conservative:
  - avoid repeated sanitization
  - avoid mutating canonical content just to improve a preview
  - separate preview behavior from full-message fidelity

## Testing Expectations

Before finishing:
- Run the narrowest relevant tests first.
- Run broader tests if the change touches shared infrastructure.
- Do not claim success without running the relevant build/test commands or clearly stating what was not run.
- If tests fail, determine whether the issue is caused by the change or is pre-existing.

Good default targeted suites:
- HTML/rendering: `HTMLContentLoaderTests`, `HTMLDisplayWrapperTests`, `HTMLSanitizerServiceTests`, `HTMLRemoteImageAttachmentFallbackTests`, `HTMLPreviewScaleCalculatorTests`
- Preview classification/cards: `NewsletterPreviewBuilderTests`, `TransactionalPreviewBuilderTests`, `EmailPreviewClassifierTests`
- Compose: `ComposeViewModelTests`, `ComposeSendOrchestratorTests`
- Chat bubble loading: `MessageBubbleLoaderTests`, `MessageBubbleViewModelTests`

## Refactor plan

- Before starting any refactor, read:
  - `docs/refactor-plan.md`
- Treat it as the current prioritized roadmap.
- Prefer implementing one scoped item at a time.
- When making changes, keep the plan updated if priorities, findings, or implementation status change.

## Refactor Rules

- Do not refactor unrelated code while implementing a feature.
- If a refactor is necessary, keep it tightly scoped to the task.
- Preserve public behavior unless the task explicitly changes it.
- Avoid new dependencies unless absolutely necessary.

## Definition Of Done

A task is done when:
- the relevant code paths were inspected before editing
- the smallest clean change was made
- the app builds successfully or the build status is explicitly stated
- relevant tests pass or the exact gap is stated
- no new warnings were introduced in the touched scope
- the summary clearly reports:
  - files changed
  - key decisions
  - tests run
  - known limitations
  - next steps only if genuinely useful
