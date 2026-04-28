---
name: build-ios-app
description: Build and test the esc-chatmail iOS app with the repo's real project, scheme, simulator defaults, and validation rules.
---

# Build IOS App

## When To Use

Use when you need to build, test, or validate any change in this repo.

## Goal

Run the real `esc-chatmail` project with the correct toolchain, scheme, and simulator, then report exactly what was run and what passed or failed.

## Workflow

1. Use the project container, not a workspace.
   - Project: `esc-chatmail.xcodeproj`
   - Scheme: `esc-chatmail`

2. Use the Xcode app toolchain explicitly.
   - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
   - If `xcodebuild` says the active developer directory is Command Line Tools, this was omitted.

3. Prefer an explicit simulator destination.
   - Default simulator: `platform=iOS Simulator,name=iPhone 17 Pro`
   - Xcode 26.4.1 currently registers the iOS simulator runtime as `26.4`; do not pin `OS=26.4.1`.
   - Reason: `Scripts/run-tests.sh` otherwise picks the first available iPhone simulator, which can land on an older runtime.

4. Use these commands.

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project esc-chatmail.xcodeproj \
  -scheme esc-chatmail \
  -configuration Debug \
  -destination "$DESTINATION"
```

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash Scripts/run-tests.sh
```

5. Start narrow, then widen only if the touched area justifies it.
   - Narrow test command pattern:

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash Scripts/run-tests.sh -only-testing 'esc-chatmailTests/<SuiteName>'
```

   - HTML/rendering changes: `esc-chatmailTests/HTMLSanitization/HTMLContentLoaderTests`, `esc-chatmailTests/HTMLSanitization/HTMLDisplayWrapperTests`, `esc-chatmailTests/HTMLSanitization/HTMLSanitizerServiceTests`, `esc-chatmailTests/HTMLSanitization/HTMLRemoteImageAttachmentFallbackTests`, `esc-chatmailTests/HTMLPreviewScaleCalculatorTests`
   - Preview routing changes: `esc-chatmailTests/Preview/NewsletterPreviewBuilderTests`, `esc-chatmailTests/Preview/TransactionalPreviewBuilderTests`, `esc-chatmailTests/Preview/EmailPreviewClassifierTests`
   - Compose changes: `esc-chatmailTests/Compose/ComposeViewModelTests`, `esc-chatmailTests/Compose/ComposeSendOrchestratorTests`
   - Chat bubble/thread changes: `esc-chatmailTests/MessageBubbleLoaderTests`, `esc-chatmailTests/MessageBubbleViewModelTests`

6. Use the repo test wrapper for tests.
   - `Scripts/run-tests.sh` sets the scheme/configuration and skips `PerformanceRegressionTests` by default.
   - Pass `--performance` only when performance coverage is part of the task.
   - Prefer setting `DESTINATION` explicitly for reproducible runs and to avoid failures when a previously documented runtime is no longer installed.

7. Known failure patterns in this repo.
   - `xcodebuild` or `simctl` fails before build starts: toolchain is pointed at Command Line Tools instead of Xcode.
   - Tests run on an unexpected simulator/runtime: `DESTINATION` was left implicit.
   - HTML test failures after preview work: check for preview logic leaking into the full-message path.
   - WKWebView regressions after HTML changes: check `HTMLContentLoader`, `HTMLSanitizerService`, `HTMLDisplayWrapper`, `BaseEmailWebView`, and `HTMLRemoteImageAttachmentFallback` together.

## Output Format

- `Build:` command and destination used
- `Result:` succeeded or failed
- `Coverage:` exact tests or targets run
- `Failures:` first actionable error or failing test
- `Next step:` smallest follow-up action

## Guardrails

- Never claim build or test success without running the command.
- Do not switch to `.xcworkspace`; this repo is using `esc-chatmail.xcodeproj`.
- Do not rely on "first available simulator" when documenting defaults.
- Run the narrowest relevant tests first.
- If only tests were run, say that the app build was validated through `xcodebuild test`, not a separate standalone build command.
