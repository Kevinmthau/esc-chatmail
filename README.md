# esc-chatmail

`esc-chatmail` is a Gmail client for iOS that makes email feel like chat while preserving original-message fidelity where it matters.

## Product Overview

- Gmail client for iPhone.
- Chat-style conversation experience for reading, replying, and composing email.
- Full original email rendering is preserved for message views where source fidelity matters.
- Chat previews use derived, layout-stable representations optimized for quick scanning in conversation threads.

## Requirements

- Xcode app toolchain installed at `/Applications/Xcode.app/Contents/Developer`.
- iOS simulator destination: `platform=iOS Simulator,name=iPhone 17 Pro`.
- App deployment target: iOS 17.6.
- Xcode project: `esc-chatmail.xcodeproj`.
- Scheme: `esc-chatmail`.
- SwiftPM dependencies are resolved through the Xcode project.

For command-line builds, use the Xcode app toolchain rather than the standalone Command Line Tools. The wrapper scripts set `DEVELOPER_DIR` and the default simulator destination for reproducible local runs.

## Build

```bash
./Scripts/codex-build.sh
```

The wrapper runs a Debug build of the `esc-chatmail` scheme in `esc-chatmail.xcodeproj` against the default iPhone 17 Pro simulator destination. You can pass additional `xcodebuild` arguments through the wrapper when needed.

## Test

Run the default test suite:

```bash
./Scripts/codex-test.sh
```

Run a targeted test suite:

```bash
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/<SuiteName>'
```

For example:

```bash
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/HTMLDisplayWrapperTests'
```

`Scripts/run-tests.sh` uses the `esc-chatmail` scheme and Debug configuration. The default test plan excludes timing-sensitive performance tests. Run those separately when relevant:

```bash
./Scripts/codex-test.sh --performance
```

## Architecture Overview

### App Boot Path

- `esc-chatmail/App/esc_chatmailApp.swift` starts the app, initializes `Dependencies.shared`, restores auth, waits for Core Data, and prewarms WebKit.
- `esc-chatmail/App/ContentView.swift` chooses between sign-in and the main conversation UI.

### Main Views

- `esc-chatmail/Views/Main/ConversationListView.swift`
- `esc-chatmail/Views/Chat/ChatView.swift`
- `esc-chatmail/Views/Compose/ComposeView.swift`

### State Management

- Shared app services are provided by `esc-chatmail/Services/Dependencies.swift` through SwiftUI environment objects.
- Screen state is usually owned by `@StateObject` view models such as `ConversationListViewModel`, `ChatViewModel`, and `ComposeViewModel`.
- View models compose smaller services instead of pushing business logic into the view layer.
- `ViewModelTaskManager` is the common helper for cancelling or deduplicating async UI work.

### Email Rendering

The email rendering pipeline is intentionally split into stages:

1. Source selection and recovery: `HTMLContentLoader`, `HTMLContentHandler`, `HTMLContentRecoveryService`.
2. Sanitization and safety: `HTMLSanitizerService`, `HTMLRemoteImageAttachmentFallback`, URL and CSS sanitizers.
3. Presentation wrapping: `HTMLDisplayWrapper`.
4. Rendering surfaces:
   - Full message: `HTMLMessageView` -> `HTMLWebView` -> `BaseEmailWebView(.fullInteractive)`.
   - Preview routing: `EmailContentSection`, `NewsletterPreviewBuilder`, `TransactionalPreviewBuilder`, `MiniEmailWebView`.

Full-message rendering should prioritize fidelity to the original email. Chat previews may use derived representations optimized for speed, clarity, and stable layout. Preview-specific transformations should stay out of the full-message rendering path unless there is a clear product requirement.

## Security And Privacy

- OAuth tokens, user credentials, installation IDs, and other sensitive runtime values use Keychain-backed services such as `KeychainService` and `TokenManager`.
- Google OAuth app configuration is build-time app configuration. It is not an end-user credential or an OAuth token.
- Do not commit user credentials, OAuth tokens, private keys, server-side secrets, or personal account data.
- Do not log tokens or sensitive account data while debugging.

See `esc-chatmail/Configuration/SECURITY_SETUP.md` for the current local configuration guidance.

## Development Guidelines

- Prefer small, reviewable diffs.
- Preserve existing architecture unless there is a clear improvement.
- Keep full-message email rendering separate from chat-preview behavior.
- Avoid repeated sanitization, wrapping, or recovery passes in the email rendering path.
- Preserve Core Data batching and prefetching in inbox and chat list work.
- Treat chat scroll timing and `MiniEmailWebView` height changes carefully.
- Run the narrowest relevant tests first, then broaden test coverage when a change touches shared infrastructure.

## Additional Documentation

- `AGENTS.md` - contributor and agent workflow guidance.
- `esc-chatmail/Configuration/SECURITY_SETUP.md` - security configuration setup.
