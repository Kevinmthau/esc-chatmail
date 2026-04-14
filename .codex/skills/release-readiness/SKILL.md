---
name: release-readiness
description: Assess esc-chatmail release risk across inbox, thread, compose, scrolling, and email rendering, then report the smallest required fixes before sharing.
---

# Release Readiness

## When To Use

Use before sharing a branch, cutting a release candidate, or deciding whether a change is safe to hand to testers.

## Goal

Produce a concrete ship/no-ship readout for this app with the top risks and the minimum fix list needed before sharing.

## Workflow

1. Validate the build and tests with the repo defaults.
   - Project: `esc-chatmail.xcodeproj`
   - Scheme: `esc-chatmail`
   - Default simulator: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4`
   - Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

2. Review the core user flows.
   - Inbox: `esc-chatmail/Views/Main/InboxListView.swift`
   - Chat list: `esc-chatmail/Views/Main/ConversationListView.swift`
   - Thread view: `esc-chatmail/Views/Chat/ChatView.swift`, `ChatMessagesView.swift`, `MessageBubble.swift`
   - Full email rendering: `esc-chatmail/Views/Chat/HTMLMessageView.swift`
   - Compose: `esc-chatmail/Views/Compose/ComposeView.swift`, `esc-chatmail/ViewModels/ComposeViewModel.swift`

3. Check the failure-prone behaviors first.
   - Thread scroll stability and keyboard interactions
   - HTML preview card routing versus full-message fidelity
   - Preview height jitter inside chat bubbles
   - Reply/forward flows and compose dismissal
   - Attachments, inline `cid:` assets, and remote image fallbacks

4. Review performance-sensitive areas.
   - WebKit prewarm in `WebKitPrewarmer`
   - `ChatMessagesView` scroll task sequencing
   - `MessageBubbleLoader` / `ProcessedTextCache` / participant prefetching
   - Core Data `FetchRequest` batch sizes and prefetching in inbox/chat lists

5. Prefer the smallest credible fix list.
   - Blocker/high risks should map to a concrete patch or explicit follow-up.
   - Do not turn release review into a broad cleanup pass.

## Output Format

- `Verdict:` ready, ready with caveats, or not ready
- `Top risks:`
  - severity as `blocker`, `high`, `medium`, or `low`
  - file or flow affected
  - concise explanation
- `Smallest fixes before sharing:` flat list
- `Validation run:` build/test commands and scope

## Guardrails

- Findings come first; summaries are secondary.
- Do not call the app ready without running a real build/test command.
- Keep the focus on inbox, thread view, compose, scrolling, and email rendering.
- Preserve the repo's preview-vs-original separation when judging risk.
- Recommend the fewest fixes that materially reduce user-visible risk.
