# Repository Guidelines

## Project Structure & Module Organization
- `esc-chatmail/` contains the app source (Swift/SwiftUI), including `Services/`, `Views/`, `Models/`, and `Resources/`.
- `esc-chatmail.xcodeproj/` holds the Xcode project settings.
- `esc-chatmailTests/` contains unit tests; `esc-chatmailUITests/` contains UI tests.
- Configuration lives in `esc-chatmail/Configuration/` (see security notes below).

## Build, Test, and Development Commands
Use `xcodebuild` with the `esc-chatmail` scheme:
- Build (Debug, device): `xcodebuild build -scheme esc-chatmail -configuration Debug -sdk iphoneos`
- Build (Debug, simulator): `xcodebuild build -scheme esc-chatmail -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16'`
- Build (Release): `xcodebuild build -scheme esc-chatmail -configuration Release -sdk iphoneos`
- Run all tests: `xcodebuild test -scheme esc-chatmail -configuration Debug`
- Run a specific test: `xcodebuild test -scheme esc-chatmail -only-testing 'esc-chatmailTests/ConversationMergerTests'`
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
