# Plan: make the Mac app look and work like Messages on the Mac

Written 2026-11-10 against `main` at `fd9b773d`, from a screenshot of Messages on macOS 26 and from reading the app's views. **Status: the spike and PR 1 are done (same day); PRs 2 to 6 have not started.** The spike's results are under "Spike results". PR 1 is compiled and unit-tested on both platforms but has not been seen in the app; "PR 1 as built" lists what to check there. The Mac app's current look was read from the code, not seen: the app holds real mail, so nobody launches it to check UI (see "How each PR is checked").

This plan is the detailed version of the Windows, Layout, Toolbar and Selection items of Phase 2 in `docs/mac-app-plan.md`, plus a restyle that Phase 2 did not ask for. The Settings scene, file drag and drop, Save Attachment, the name and the icon stay in that document.

## Summary

- **Mac only.** iOS keeps its `NavigationStack`, its bottom bar and its bubbles exactly as they are. The rule from Phase 1 holds: iOS behavior doesn't change, and the full iOS suite stays green after every PR.
- **The big change is structure, not paint.** Today the Mac shows the iPhone UI in a window: one column that pushes a chat and pops back. Messages is two columns, a sidebar of conversations and the open chat beside it. That needs a `NavigationSplitView`, a selection the root owns, and a chat that no longer leaves by calling `dismiss()`.
- **A chat that stays open all day changes one behavior.** Opening a chat marks it read. In a split view a chat is "open" whenever it is selected, including while the app sits behind other windows. The mark-read gate needs the window's focus added to it on the Mac (PR 1).
- **Six PRs after one spike** (done; see "Spike results"). Split view first; then sidebar, header, bubbles and composer, each in its own files; inline New Message last and optional.
- **Views share code through values, not `#if`.** Row metrics, bubble style and status-line arrangement become values with an iOS case that equals today's constants, and tests pin that. Mac-only views are whole files in `#if os(macOS)`.

## What the screenshot shows, and what the app has

Sizes are read off the screenshot and are approximate (it may have been scaled). The final constants get measured against Messages on the Mac, side by side, the way the iOS row was (`ConversationRowView.swift:55`).

| Surface | Messages on the Mac | The app today (`file`) |
|---|---|---|
| Window | One window, no title. Sidebar about 35% of the width, glass, full height, with the traffic lights in it | `WindowGroup` holding `NavigationStack { ConversationListView }` (`ContentView.swift:19`) |
| Sidebar top | Filter button (glass circle, badge) at the trailing edge; search field below it, full width | Select and Filter in the toolbar; search and compose in a bottom bar (`ConversationListView.swift:266`) |
| Compose button | Leading edge of the chat's toolbar | Bottom bar, opens a sheet |
| Row | Unread dot, avatar about half the row's height, bold name, time at top right, two-line preview. No chevron. Separator starts at the text | Same parts at iPhone sizes, plus a chevron (`ConversationRowView.swift:184`) |
| Selected row | Rounded fill in the accent color, white text | No selection: a tap pushes the chat (`ConversationListView.swift:88`) |
| Chat header | Avatar centered, name in a glass capsule with a chevron under it; one button at the trailing edge. The transcript blurs as it scrolls under | Title text and a ⋯ menu (`ChatView.swift:68`) |
| Bubbles | Radius about 17, a tail on the last bubble of a run. Blue with white text, gray with black text. Width grows with the window | Radius 12, no tail, gray at 20% opacity, 280 points wide at most (`MessageBubbleStyle.swift`) |
| Time | A centered line ("**Today** 2:14 PM") between groups of messages | A timestamp and an unread dot under every bubble (`MessageMetadata.swift`) |
| Receipt | "Delivered" under the newest sent bubble, at the trailing edge | "Sent · 2:41 PM" on the newest row (`MessageSendStatusLinePolicy`) |
| Avatars in the chat | None in a one-to-one chat | A 24-point avatar beside incoming messages in every chat (`MessageBubble.swift:307`) |
| Emoji-only message | Large emoji, no bubble | A normal bubble |
| Image | About 60% of the transcript's width, radius 16 | 280 points wide at most (`ImageAttachmentBubble.swift:12`) |
| Composer | "+" glass circle, capsule field, emoji button. No send button, no divider; the transcript shows through | Photo and paperclip buttons, field, send button, divider, opaque background (`ChatReplyBar.swift:85`, `ChatMessagesView.swift:1058`) |

Things Messages has that mail does not, and this plan leaves out: FaceTime, tapbacks, typing indicators, message effects, read receipts, the pinned-conversation grid, dictation in the field.

## Decisions

Each has a recommendation; none blocks the spike or PR 1.

1. **Bubbles on iOS too?** Recommended: Mac first. The new shape is a `MessageBubbleStyle` case, so iOS can adopt it later by changing one value.
2. **Send button.** Messages on the Mac has none: Return sends. Recommended: Return sends, and a send arrow appears inside the field while it has content. Without it there is no way to send with the mouse, and nowhere to show that send is waiting on an attachment. A mail send can't be unsent. The spike adds one fact: left alone, Shift-Return sends too, so PR 5 makes it a new line.
3. **Time separators instead of a timestamp under every bubble.** Recommended: yes on the Mac, with the exact time as a hover tooltip. The per-message unread dot goes with it; the sidebar's dot stays.
4. **Subject lines.** Messages has none. Recommended: leave them as they are in this pass (above the bubble). Showing a subject only when it changes is a separate product decision.
5. **What is selected at launch.** Messages selects the newest conversation. Recommended: select nothing and show a placeholder, because selecting a chat marks it read.
6. **New Message.** Messages writes a new message in the chat column, not in a sheet. Recommended: keep the sheet until PR 6. Compose holds its sheet until transmission admission, and the inline version has to keep that contract.
7. **The header's trailing button.** FaceTime has no meaning here. Recommended: the existing ⋯ menu (Archive, Report Spam, Discard draft).
8. **Selection color.** Decided by the spike: the system accent. This Mac's accent is `#2E676B`, the teal in the screenshot, and a native selected row drew in it. The app's `AccentColor` asset is empty, so it already follows the system.
9. **The selected row while you type** (new, from the spike). A native list shows its selection in the accent color only while the list itself has keyboard focus. With the caret in the reply field, the selected conversation turns gray; in Messages it stays colored. Recommended: the row draws its own fill, which the spike showed covers the native one exactly. The cost is that the row also sets its own text colors.

## Spike results (2026-11-10)

**How.** Four throwaway programs outside the repo, built for macOS 26 and run on macOS 27.2: bare `swiftc` executables, each window at (-30000, -30000), with no activation policy set. None was ever the active app. Geometry was read from view frames, colors from pixels of the rendered views.

**Header: the avatar goes in the toolbar, the name capsule in a bar under it.**

- The window toolbar is 52 points tall and does not grow. A `.principal` item holding a 40-point avatar over the capsule is 60 points tall: it sticks out 4 points above the window's top edge and 4 below the toolbar.
- A 40-point avatar alone fits as the `.principal` item (6 to 46 points from the top) and takes clicks.
- The capsule in `safeAreaBar(edge: .top)` sits right under the toolbar, 30 points tall with its padding, and takes clicks. The transcript's first row starts under it, 82 points from the window's top; Messages' header is about 79.
- A view the chat column draws up into the toolbar's 52 points gets no clicks there: they go to the toolbar. So the avatar has to be a toolbar item, not an overlay.
- The `.principal` item is centered 2.5 points to the right of the chat column's center, at both window widths tried and whatever the trailing item's width. Offset the capsule by the same 2.5 points.

**Sidebar: `.listStyle(.inset)` draws Messages' list; `.sidebar` does not.**

| | `.inset` | `.sidebar` |
|---|---|---|
| Selection with the list focused | Rounded fill, 10 points in from each edge, accent color (`#376368` here); the name turns white and the preview light | A lighter tint (`#4C787D`) |
| Selection without focus | Gray (`#E2E2E2`), text unchanged | Not captured |
| Separators | Drawn by default, from the text column's leading edge; none next to the selected row | None unless `.listRowSeparator(.visible)` |

- Both styles give a row 16 points of margin on each side and 4 points above and below its content.
- `Color.primary` and `Color.secondary` text adapt in a selected, focused row on their own. A blue unread dot does not; the row has to turn it white.
- `backgroundProminence` did not change when a row became emphasized in the probe. Do not build on it: pass the row whether it is selected.
- A fill the row draws itself (`listRowBackground`: 10 points in, radius 8, `selectedContentBackgroundColor`) covered the native gray selection with no pixel of it left showing (decision 9).
- Through `List(selection:)` over a `Set`: Down moved the selection, Shift-Down extended it, Delete reached `onDeleteCommand`, and the table offered the trailing and leading swipe actions.

**Toolbar and search.**

- `.searchable(placement: .sidebar)` puts the field under the toolbar row, 10 points in from the sidebar's edges, 28 points tall. That is where Messages has it.
- A toolbar item in the sidebar lands right after the traffic lights. With `ToolbarSpacer(.flexible)` before it, it sits at the sidebar's trailing edge, as in Messages.
- There is no `.badge` on toolbar content. `.badge(1)` on the `Menu` inside the item draws a count badge on the button (red by default).
- `.toolbar(removing: .sidebarToggle)` removes the Hide Sidebar button, which Messages does not have. `.toolbar(removing: .title)` hides the title.
- A `.navigation` item in the chat column sits 8 points right of the sidebar's edge. A `.primaryAction` menu with `.menuIndicator(.hidden)` is a 36-point circle at the trailing edge.

**Return in `TextField(axis: .vertical)`.**

| Key | What happened |
|---|---|
| Return | `onSubmit` ran; the text stayed |
| Shift-Return | `onSubmit` ran, the same as Return |
| Option-Return | A new line, no submit |
| Control-Return | One whitespace character, no submit |

- **Shift-Return would send.** The web app taught the opposite. An `onKeyPress(.return)` that acts only on Shift, and sends the field its own "new line" command (`insertNewlineIgnoringFieldEditor:`), added the line and did not submit.
- **`onKeyPress` runs before the text system.** A handler that took a bare Return left marked text marked: an input method never saw the key. So a bare Return must never be handled there. `onSubmit` comes from the field's own command path, after the input method.
- **After `onSubmit` the field selects all of its text, and it stays selected.** The next key replaced the whole draft. Resetting the selection through `TextField(text:selection:)` did not prevent it. A send that clears the field hides this. A send that is refused (an attachment still processing, a reply target gone) would leave the draft one keystroke from being replaced.

**Bubble tail.** One `Shape` drew both directions in light and dark: radius 17, capped at half the bubble's height; a tail 4 points wide; the incoming shape is the mirror image. The shape keeps those 4 points free on the tail's side whether or not it draws a tail, so the bubbles of a run line up.

**Not seen, and why.**

- **Glass and blur.** The captures draw none. Not seen: the glass behind the avatar's toolbar item and whether `sharedBackgroundVisibility(.hidden)` removes it, the capsule's glass, the scroll edge effect under the header, the sidebar's material behind an `.inset` list (it may need `scrollContentBackground(.hidden)`).
- **A real key window.** "Focused" was simulated by setting the row's `isEmphasized`, the way AppKit does. Menus and `Commands` were not run.
- **A real input method.** With text marked by hand and no input method running, one Return both committed the text and ran `onSubmit`. A real input method should take that first Return for itself. Check with Japanese input in the app before PR 5 ships.
- **Sidebar width.** In the probe's hand-made window, `navigationSplitViewColumnWidth(min: 240, ideal: 310, max: 420)` was ignored and the sidebar came up 144 points wide; it was set to 310 by hand. Check it in the app's `Window` scene. Answered 2026-11-11: the hand-made window was not the cause. The probe applied `toolbar(removing: .sidebarToggle)` after the width, as PR 1 then did, and that order is what makes the split view ignore the width (see "Fixed after the review of PR 382").
- **Rows inside the split view.** They did not draw in any capture, so the list was measured in a window of its own. Its frames inside the split view matched.

## PR 1: window and split view (structure only)

The largest PR, and the only one that changes behavior. Nothing is restyled.

- **Window.** On the Mac, a single `Window` scene instead of `WindowGroup`, with no title, a default size near the screenshot's, and a minimum size. One window, because `ChatReplyComposerDirectory` lets only the newest composer write a conversation's draft (`mac-app-plan.md`, "Windows").
- **Root.** `ContentView` branches: iOS keeps `NavigationStack { ConversationListView }` untouched; the Mac shows a new `MacMailboxView` (`NavigationSplitView`, sidebar and detail).
- **Sidebar.** A new `MacConversationSidebar` with `.listStyle(.inset)` (spike), not a second mode of `ConversationListView`. The iOS list's body is iOS chrome (bottom bar, selection checkboxes, a tap gesture that would swallow the click a selection needs, `navigationDestination`), and its comments record identity bugs specific to it. The two share what matters:
  - `ConversationListViewModel`, so live updates still come from its `objectsDidChange` pipeline. No `@FetchRequest` (CLAUDE.md).
  - `ConversationRowView`, the two banners, and the `onAppear`/`onDisappear` work, moved into one shared modifier so the two lists can't drift.
- **Selection.** `List(selection:)` over a `Set<NSManagedObjectID>`.
  - One selected: the detail column shows that chat, as `ChatView(...).id(objectID)`.
  - None: a "No Conversation Selected" placeholder.
  - Several (Shift-click, Cmd-click): a count with Archive and Report Spam, which call the existing selection service's batch actions.
  - A pure `MacSidebarSelectionPolicy` decides what happens when the selected conversation leaves the list: archived or deleted clears it (or moves to the next row); hidden by search or a filter keeps the chat open.
- **Leaving a chat.** `ChatView` calls `dismiss()` in three places: the drained-conversation exit, Archive and Report Spam (`ChatView.swift:172`, `303`, `307`). In a detail column there is nothing to dismiss. Give `ChatView` an `onExit` closure: iOS passes `dismiss`, the Mac clears the selection. `performConversationExitAction` already takes the closure, so the mid-send hold (`ChatConversationExitActionPolicy`) is unchanged.
- **Mark-read gate.** `isChatActiveAndUncovered` is true when the scene is active and no sheet covers the chat (`ChatView.swift:210`). On the Mac, add "this window is key and the app is active" (`appearsActive`). Not verified: what `scenePhase` reports for a Mac window behind other apps. If it stays `.active`, then without this change mail that arrives while the app is in the background is marked read unseen.
- **Composer directory.** Switching rows replaces the detail's `ChatView`. Check that the old one's `onDisappear` still calls `composerDidDisappear`, and that the unsent text of chat A is in its draft when the user comes back to A.
- **Commands and menus.**
  - Toolbar: New Message at `.navigation` in the chat column; the filter menu in the sidebar with `ToolbarSpacer(.flexible)` before it; `.searchable(placement: .sidebar)`; the sidebar toggle and the title removed. All as measured in the spike.
  - Column width: check that `navigationSplitViewColumnWidth` holds in the `Window` scene; the probe's window ignored it.
  - Keys: Cmd-N new message, Cmd-F search, Cmd-R sync (`.refreshable` has no gesture on the Mac), Delete archives, arrows move the selection.
  - Right-click on a row: Archive, Mark as Read or Unread, Report Spam.
- **Tests.** `MacSidebarSelectionPolicy`, the exit routing and the mark-read gate are pure functions with suites in `Mac.xctestplan`.

### PR 1 as built (2026-11-10)

**What is there.**

- `MailboxRootView` picks the shape: iOS is unchanged; the Mac shows `MacMailboxView`, a `NavigationSplitView` of `MacConversationSidebar` and `MacMailboxDetail`. The Mac app is one `Window` scene.
- The sidebar is an `.inset` list with `List(selection:)`, search at `.sidebar`, the filter menu at the sidebar's trailing edge, swipe actions, a right-click menu and Delete. The rows are still the iPhone's (chevron, iPhone metrics) until PR 2.
- Menu commands (`MailboxCommands`): New Message (Cmd-N, in place of New Window), Get New Mail (Cmd-R), Search (Cmd-F).
- Shared by both lists, so they cannot drift: the view model, the row, the banners, `ConversationFilterMenu`, `conversationListLifecycle` and `ConversationReference.openableConversation`.

**Where it differs from the plan above, or settles what the plan left open.**

- **What is selected after a conversation leaves.**
  - Your own Archive or Report Spam on the list (Delete, the menu, a swipe) moves the selection to the next row, so Delete, Delete, Delete works from the keyboard.
  - Everything else selects nothing: the chat's own ⋯ menu, a conversation that drains, one archived from another device. Selecting a row marks it read, and in those cases you did not pick one.
- **Closing the window quits the app.** SwiftUI does that for an app whose only scene is a `Window`. Before, with a window group, the app kept running. A quit still waits for a send in flight. Kevin decided on 2026-11-11 to keep this, over an app that stays running with its window closed (`mac-app-plan.md`, decision 7).
- **The sidebar's selection is its own,** not the select-mode set in `ConversationSelectionService`. That set is pruned to the visible rows on every list publish; bound to it, typing in the search field would close the open chat. Batch actions take the row IDs instead (`archiveConversations(withIDs:)`).
- **`dismiss()` in the chat column closes the window,** which is worse than the "nothing to dismiss" this plan assumed, since closing the window quits. `ChatView` now closes itself only through `exitChat()`, and a test reads the source to keep it that way.
- **The chat column is `Equatable` on the selection.** The mailbox view re-evaluates on every list publish, including each search keystroke; without the check each one would re-evaluate the open transcript.

**Checked.**

- The Mac app and its test target compile, unsigned, with no new warnings. The unsigned app was deleted and never launched.
- The full iOS suite passes: 4,847 tests.
- `Mac.xctestplan` passes in the signed, sandboxed test host: 237 tests in 19 suites, the two new ones (`MacSidebarSelectionPolicyTests`, `ChatViewExitTests`) among them. That host is the app itself, so the new `Window` scene and its commands at least start. It stays on the loading view (`initializeApp()` does nothing under tests), so it never builds the mailbox.
- Each new regression test was run against the change it guards, with that change undone: 11 of 12 failed as they should. The twelfth cannot fail that way and says so (`HONEST SCOPE`: the per-call task key in `ConversationSelectionService`).
- In an off-screen stand-in for the chat column (the spike's harness, not the app's views):
  - A chat swapped out by a selection change gets its `onDisappear`, which is what saves its draft and withdraws its composer. The new chat's `onAppear` runs first, then the old one's `onDisappear`.
  - 20 unrelated changes in the parent re-evaluated the column 20 times without the `Equatable` conformance, and not once with it.
- **Rebased 2026-11-11** onto `main` at `01fa227a`, which had gained the sheet presenter (PRs 379 and 380).
  - One change was needed: the New Message sheet in `MacMailboxView` is now presented with `appSheet(isPresented:mac:)`, as `main` requires of every sheet the Mac compiles. Before that the Mac build did not compile, because `macSheetSize(_:)` is gone.
  - Run again on the rebased tree: the full iOS suite, 4,880 tests, and `Mac.xctestplan` in the signed, sandboxed test host, 237 tests in 19 suites. All passed.
  - The revert-checks above were not repeated, and the app has still not been launched with this.

**Found by reading, not fixed here.**

- **A draft can lose its last words on a very fast A, B, A.** Leaving chat A schedules its draft save, which waits its turn behind other conversation mutations. If A is selected again before that save runs, the new composer loads the older stored draft and the pending save is dropped as stale (`ChatReplyComposerDirectory`). iOS has the same order of events but a pop and a push take half a second; arrow keys take none. The loss is the text typed since the last autosave (350 ms after a keystroke, longer if a sync holds the queue). It belongs with PR 5.
- **Mail that arrives while the app is in the background stays unread after you come back** to the chat it is in, until you select another row and return. The gate only stops the marking; nothing marks on return. iOS behaves the same when you return to an open chat. Decide in PR 5 whether returning should mark it.
- **Arrow keys open, and mark read, every conversation they pass,** because that is what selecting does. If that is wrong for mail, the fix is a short pause before a newly selected chat opens.

**Fixed after the review of PR 381 (2026-11-11).** Two findings from that review. Neither fix has been seen in the app.

- **The sidebar could be dragged closed, with no control to reopen it.** Removing the toggle button does not stop a drag of the divider from closing the sidebar. `MacMailboxView` now owns the split view's column visibility and puts both columns back when the split view reports the sidebar closed (`MacSidebarVisibilityPolicy`).
  - Measured in a throwaway off-screen program on macOS 27.2, with a mouse drag of the divider sent to the split view. With no binding, and with `.constant(.all)`, the sidebar closed and stayed closed. With the reset it closed and reopened four times while the drag was held past the edge, and it was open when the drag ended.
  - That program's window ignored the column's minimum width, as the spike's did, so where the divider comes to rest in the app is not known.
- **New Message from the menu while a sheet is up.** Command-N under the reader, Participants or the Sign Out… confirmation asked for a second sheet on the same window. A Mac window shows one sheet at a time, so it would wait behind the first and appear when that one closed. The command now beeps and opens nothing while the focused window has a sheet attached (`MailboxMenuPolicy`), the rule the Sign Out… command already follows. Search and Get New Mail are unchanged.

**Fixed after the review of PR 382 (2026-11-11).** That review's two findings about the sidebar fix above, and one thing the measuring turned up. None of it has been seen in the app.

Measured on macOS 27.2 in a second throwaway program, this one a SwiftUI app with a `Window` scene, an invisible window and a sidebar carrying `MacConversationSidebar`'s modifiers. The divider was dragged from 320 points to 40 points past the window's leading edge with mouse events 16 ms apart, twice (70 events, then 30).

- **The reset alone is not a fix.** With only the visibility reset, the sidebar closed and reopened 69 times in those two drags: once a drag had gone far enough to close it, nearly every further event closed it again. The window ended 320 points wider: AppKit widens the window when it reopens a sidebar. The earlier measurement counted four in its one drag; how many events that drag had was not recorded.
- **The sidebar can no longer be dragged closed.** `macSplitViewColumnCannotCollapse()` puts an empty AppKit view in the sidebar column. It finds the `NSSplitViewItem` it is inside and turns `canCollapse` off (`MacSidebarCollapseGuardView`). With it the sidebar never closed, the visibility binding was never written, the divider stopped at the 260-point minimum and the window kept its width.
  - SwiftUI turns `canCollapse` back on: at each of six state changes of the split view's content, and after each write of the visibility binding. One assignment did not last, so the view holds it off with a key-value observation, which turned it off again every time.
  - The reset stays as the fallback (`MacSidebarVisibilityPolicy`). A sidebar closed in code (`NSSplitViewItem.isCollapsed`) was still reported as `.detailOnly` and reopened. `toggleSidebar(_:)` did nothing while `canCollapse` was off.
  - The guard depends on how SwiftUI builds a split view on macOS 27.2: an `NSSplitView` whose delegate is an `NSSplitViewController`, with the column's content inside one item's view. If a later system builds it another way, the guard finds nothing and the reset is all there is.
- **The sidebar's width was being ignored.** With `navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)` applied before `toolbar(removing: .sidebarToggle)`, the order PR 1 shipped, the sidebar came up 144 points wide with a 140-point minimum and no maximum. With the width applied last it came up 320 wide with a 260 minimum and a 480 maximum. `MacMailboxView` now applies it last, and `MacMailboxViewSourceTests` pins the order.
- **The review's second finding needed no change.** It asked whether a sidebar could end up closed without the reset hearing of it. A launch whose saved split view frames had the sidebar closed opened it with nothing reported: the state starts at `.all` and SwiftUI applies it. And on macOS 27.2 `.automatic` compares equal to `.doubleColumn`, so `.detailOnly` is the only one of the four values that does not show the sidebar, and a rule correcting "everything not known to be open" would be the same rule.
- Narrowing the window in code to 300 points, below its 700-point minimum, closed nothing whether `canCollapse` was on or off, and SwiftUI put the window back at 700.

**Not seen: check in the signed, sandboxed app.**

- The whole window: column widths, the toolbar, the empty and multiple-selection states.
- Selecting, Shift- and Cmd-click, arrows, Delete, the right-click menu, swipes.
- That closing a chat by its ⋯ menu's Archive clears the column and does not close the window.
- That mail arriving with the app in the background stays unread.
- The three menu commands, and whether `.searchable` adds a Find command of its own beside Search.
- Typing in the search field with a long chat open: the transcript should not stutter.
- Whether the sidebar's width holds: it should open 320 points wide and resize between 260 and 480.
- Dragging the sidebar's divider to the window's left edge: the divider should stop at 260 points and the sidebar should never close. If it closes and reopens, the guard did not find its split view item.
- Command-N with the reader or Participants open: a beep, and no New Message sheet when that sheet closes.

## PR 2: the sidebar's look

- **Row metrics as a value.** `ConversationRowView` takes a `ConversationRowMetrics`: `.iOS` holds today's constants unchanged, `.mac` holds the Mac's (avatar about 40 points, 13-point bold name, 13-point preview, no chevron). A test pins `.iOS` to today's numbers.
- **Selection** (decision 9). The sidebar passes each row whether it is selected. If the row draws its own fill: `listRowBackground` with the spike's geometry (10 points in, radius 8), in the accent color while the window is active and gray while it is not, and the row sets white text and a white unread dot to match. If the native selection stays: only the dot needs the row's help.
- **Separators** come with the `.inset` style, from the text column. Keep the row's `listRowSeparatorLeading` guide so an initials avatar doesn't pull them left (`ConversationRowView.swift:73`).
- **Filter button.** `.badge` on the `Menu` while a filter other than All is on.
- **Check in the app:** the sidebar's material behind the `.inset` list, which the captures could not show.

## PR 3: the chat header

- **Avatar and name capsule,** as the spike measured: the avatar (`AvatarStackView`, 40 points) is the `.principal` toolbar item; the capsule is the content of `safeAreaBar(edge: .top)` on the transcript, shifted 2.5 points right to sit under it. Both open Participants.
- **The bar changes the transcript's top inset** by 30 points, a constant for every chat. The reveal pass anchors at the bottom, so this should not disturb it; check a short chat (fewer rows than fill the window) and a long one.
- **Check in the app:** the glass the toolbar puts behind the avatar (`sharedBackgroundVisibility(.hidden)` if it shows), and the blur under the header.
- **Photos.** `ChatViewModel` already loads `ParticipantInfo` for the title (`ChatViewModel.swift:1400`) and keeps only the name and the count. Publish the photos and names it already has, with the same `maxParticipants: 4`, or the row and the chat fork the rollup cache (`ConversationRowView.swift:6`).
- **Click on the capsule** opens Participants, as the title does today, and not for a list conversation (`allowsParticipantListPresentation`). It stays a sheet; a popover is later polish.
- **Trailing edge:** the ⋯ menu.

## PR 4: bubbles and the transcript

The transcript's scroll timing is delicate (AGENTS.md), and the reveal pass depends on row identity and on rows not changing height after they mount. So every item below is decided from the row model at mount, and row identity does not change.

- **Style.** A new `MessageBubbleStyle` case for the Mac: radius, padding, 13-point text, opaque gray for incoming (it sits on a white pane), system blue for outgoing.
- **Tail.** A `BubbleShape` (drawn in the spike: radius 17 capped at half the height, a 4-point tail, 4 points kept free on the tail's side in every bubble) replaces `.cornerRadius(style.bubbleCornerRadius)` at its three sites in `MessageContentView.swift` (the loading pill, the text bubble, the forwarded bubble) and the literal 12 on the no-preview placeholder. The tail goes on the last bubble of a run; `ChatMessageRowGrouping.isLastFromSender` already computes that for both directions.
- **Spacing.** Tight inside a run, wider between runs, as padding inside the row. The `LazyVStack`'s own spacing stays one constant.
- **Width.**
  - Text bubbles take a share of the transcript's width (measure Messages; about 65%), from the `GeometryReader` the transcript already has (`ChatMessagesView.swift:300`), so text reflows when the window resizes.
  - Images get a larger fixed cap, and preview cards keep theirs. `ImageAttachmentBubble` reserves its geometry at mount on purpose, and AGENTS.md warns that preview sizing changes destabilize scrolling.
- **Avatars.** None in a one-to-one chat. In a group, on the last bubble of an incoming run, with the sender's name above the first.
- **Time separators.** A centered line above a row when the day changes or the gap since the previous message passes a threshold.
  - It is drawn inside that row, not as a row of its own, so `ChatTranscriptIdentityPolicy`, `markRowRealized` and the newest-row check are untouched.
  - A pure `ChatTimestampSeparatorPolicy` decides from the previous row's date, read the way `nextMessage` is read today (`rowForGrouping`, which already reads past the window's edge).
  - Risk: the first row of a loaded window. If its separator appears or disappears when older rows load above it, the content above the viewport changes height. Test paging up through a long chat.
- **Status line.** A Mac arrangement in `MessageSendStatusLinePolicy`: "Sent" alone under the newest sent bubble. "Sending…", "Not sent", "Delivery unknown" and the failed-send badge keep their meaning and colors. Not "Delivered": Gmail does not report delivery.
- **Large emoji.** A message of one to three emoji draws without a bubble. A pure policy over the stored preview text, so the row's height is known at mount.

## PR 5: the composer

- **Keep the structure, change the drawing.** `ChatReplyComposerOverlay` stays an overlay whose measured height feeds `ChatBottomInsetPolicy`. Do not move it to `safeAreaBar`: the transcript's bottom inset and anchor pass are built on that measurement. On the Mac it loses the divider and the opaque background.
- **Layout.** A "+" glass circle that opens a menu of the two pickers `AttachmentPicker` already has (Photos, Files); a capsule field; an emoji button that opens the system character palette.
- **Return sends** (decision 2), through the same `onSend` closure and the same `canSend` check as the button. Nothing on the send path moves, and nothing is added between the barrier and the request. Shift-Return and Option-Return add a line.
- **The field.** Recommended: a Mac-only `NSTextView` in an `NSViewRepresentable` under `Platform/`, whose delegate maps the text system's commands (`insertNewline:` sends, the Shift and Option forms add a line). Commands arrive after an input method has had the key, and a text view does not select its text after Return. The spike found two problems with keeping SwiftUI's `TextField`: Shift-Return submits, and after any submit that leaves the text in place the whole draft is selected. If `TextField` stays, it needs the Shift-only `onKeyPress` and a way to clear that selection, and never an `onKeyPress` that takes a bare Return.
- **Check in the app, with Japanese input:** the Return that confirms a word does not send.
- **Focus.** Selecting a conversation puts the caret in the field. Escape clears a reply target.
- **Reply indicator and attachment strip** sit above the capsule, restyled to match.

## PR 6 (optional): New Message in the chat column

Messages shows a "New Message" row in the sidebar and writes the message where the chat goes.

- `ComposeView(mode: .newMessage)` moves from a sheet into the detail column, with the "To:" field at the top and the composer at the bottom.
- The contract to keep: compose keeps its content until transmission admission, and a pre-barrier failure rolls back to the composer (`.rollBackToComposer`). Selecting another row mid-compose is the new "sheet dismissed" and needs the same answer the sheet gives today.
- Extend `ComposeSendOrchestratorTests` and `OutboundMessageCoordinatorTests`. Forward stays a sheet.

## How each PR is checked

- **Compile, both platforms.** The iOS build, and `DESTINATION='platform=macOS' ./Scripts/codex-build.sh --for-testing CODE_SIGNING_ALLOWED=NO`. Delete the unsigned `esc-chatmail.app` afterwards; it is unsandboxed and must never be launched.
- **Tests.** The narrowest iOS suites while working and the full iOS suite before merge. New policy suites go into `Mac.xctestplan`, with `Revert-check:` comments.
- **Look.** Compile the real view files into the off-screen probe where they have no app dependencies (row, bubble shape, composer bar, header), render to PNG, and compare with the screenshot in light and dark.
- **Not checkable without the app:** the split view with real data, focus, menus, the mark-read gate, trackpad scrolling under the header, and window resizing over a long chat. Kevin checks those in the signed, sandboxed build, and each PR lists what was not seen.

## Risks

- **Mail marked read that nobody saw** (PR 1). The worst outcome here; it lands with the split view, not after.
- **The transcript's reveal and anchoring** were tuned on iOS inside a `NavigationStack`. PR 1 changes its container and PR 4 its row heights. Keep both changes free of post-mount height changes, and test long chats and resizing.
- **A send by accident.** Return sends mail that can't be unsent. The marked-text case is measured in the spike before PR 5 is written.
- **Two lists drifting.** The Mac sidebar and the iOS list share the view model, the row and the lifecycle modifier; only the chrome differs.
- **What the spike could not see.** Glass, a real key window and a real input method ("Not seen, and why"). Each is a named check in the PR it belongs to.
