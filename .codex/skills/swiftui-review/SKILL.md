---
name: swiftui-review
description: Review or change esc-chatmail SwiftUI code with repo-specific attention to state ownership, identity, side effects, navigation, and scroll stability.
---

# SwiftUI Review

## When To Use

Use when changing or reviewing SwiftUI screens, view models, or list/thread/compose behavior.

## Goal

Find the smallest safe change or the highest-signal review findings without destabilizing list identity, chat scrolling, or email preview rendering.

## Workflow

1. Start in the real entry points.
   - App bootstrap: `esc-chatmail/App/esc_chatmailApp.swift`
   - Auth gate: `esc-chatmail/App/ContentView.swift`
   - Chats/inbox: `esc-chatmail/Views/Main/ConversationListView.swift`, `esc-chatmail/Views/Main/InboxListView.swift`
   - Thread: `esc-chatmail/Views/Chat/ChatView.swift`, `esc-chatmail/Views/Chat/ChatMessagesView.swift`, `esc-chatmail/Views/Chat/MessageBubble.swift`
   - Compose: `esc-chatmail/Views/Compose/ComposeView.swift`

2. Trace state ownership before editing.
   - App-wide dependencies come from `Dependencies.shared` and `@EnvironmentObject`.
   - Screen state usually lives in `@StateObject` view models such as `ConversationListViewModel`, `ChatViewModel`, and `ComposeViewModel`.
   - View models compose services instead of stuffing logic directly into views.

3. Check identity and diffing.
   - Core Data rows should stay keyed by stable identity such as `objectID`.
   - Watch `ForEach(Array(...enumerated()), id: \.element.objectID)` patterns in chat and list screens.
   - Avoid adding unstable `.id(...)` modifiers that force view recreation, especially around `MessageBubble`, `MiniEmailWebView`, or `NavigationStack` destinations.

4. Check recomputation and side effects.
   - Review `.task(id:)`, `.onAppear`, `.onDisappear`, and `.onChange` for repeated async work.
   - Pay attention to `MessageBubble` content loading, `EmailContentSection` preview loading, and `ChatMessagesView` scroll tasks.
   - Prefer moving repeated work into existing loaders, caches, or `ViewModelTaskManager` rather than adding new ad hoc tasks in views.

5. Check navigation and presentation.
   - `ConversationListView` uses `navigationDestination(item:)` plus composer/settings sheets.
   - `ChatView` uses several `sheet(item:)` and `sheet(isPresented:)` flows for full message view, forward compose, and contacts.
   - `ComposeView` has both standard and iMessage-style presentation paths.

6. Check scroll stability explicitly.
   - `ChatMessagesView` has staged bottom-scroll tasks and keyboard-driven scroll adjustments.
   - `MiniEmailWebView` height measurement can change cell height after first render.
   - Conversation/inbox lists depend on stable row identity and batched Core Data fetches.

7. Run targeted validation.
   - Compose work: `esc-chatmailTests/Compose/ComposeViewModelTests`
   - Chat bubble/loading work: `esc-chatmailTests/MessageBubbleLoaderTests`, `esc-chatmailTests/MessageBubbleViewModelTests`
   - Preview routing work: preview tests plus HTML tests

## Output Format

- `Findings:` ordered by severity, with file references
- `Risks:` identity, side effects, navigation, or scroll regressions not fully covered
- `Validation:` tests run or still needed

## Guardrails

- Prefer findings and minimal fixes over architectural rewrites.
- Do not move shared state upward unless the current owner is clearly wrong.
- Do not break visible behavior in chats, compose, or previews unless the task explicitly changes it.
- Treat list identity and scroll position as product behavior, not incidental implementation details.
- Keep preview-specific work out of the full-message rendering path.
