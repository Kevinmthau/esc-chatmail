# Plan: make the Mac app look and work like Messages on the Mac

Written 2026-11-10 against `main` at `fd9b773d`, from a screenshot of Messages on macOS 26 and from reading the app's views. **Status: the spike and PR 1 are done (same day), PR 2 is merged (PR 387, 2026-11-12), PR 3 is merged (PR 389, 2026-11-12) and PR 4 is built (2026-11-12); PRs 5 and 6 have not started.** The spike's results are under "Spike results". PRs 1 to 4 are compiled and unit-tested on both platforms but have not been seen in the app; "PR 1 as built" to "PR 4 as built" list what to check there. The Mac app's current look was read from the code, not seen: the app holds real mail, so nobody launches it to check UI (see "How each PR is checked").

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
9. **The selected row while you type** (new, from the spike). A native list shows its selection in the accent color only while the list itself has keyboard focus. With the caret in the reply field, the selected conversation turns gray; in Messages it stays colored. Recommended: the row draws its own fill, which the spike showed covers the native one exactly. The cost is that the row also sets its own text colors. **PR 2 built the recommendation** (2026-11-11). Kevin had been told it was unconfirmed and has not said otherwise; going back to the list's own selection means deleting the row's `listRowBackground` and its palette argument in `MacConversationSidebar`.

## Spike results (2026-11-10)

**How.** Four throwaway programs outside the repo, built for macOS 26 and run on macOS 27.2: bare `swiftc` executables, each window at (-30000, -30000), with no activation policy set. None was ever the active app. Geometry was read from view frames, colors from pixels of the rendered views.

**Header: the avatar goes in the toolbar, the name capsule in a bar under it.**

- The window toolbar is 52 points tall and does not grow. A `.principal` item holding a 40-point avatar over the capsule is 60 points tall: it sticks out 4 points above the window's top edge and 4 below the toolbar.
- A 40-point avatar alone fits as the `.principal` item (6 to 46 points from the top) and takes clicks.
- The capsule in `safeAreaBar(edge: .top)` sits right under the toolbar, 30 points tall with its padding, and takes clicks. The transcript's first row starts under it, 82 points from the window's top; Messages' header is about 79.
- A view the chat column draws up into the toolbar's 52 points gets no clicks there: they go to the toolbar. So the avatar has to be a toolbar item, not an overlay.
- The `.principal` item is centered 2.5 points to the right of the chat column's center, at both window widths tried and whatever the trailing item's width. Offset the capsule by the same 2.5 points. That is for an item on the toolbar's glass. PR 3 takes the avatar off it, and the item is then centered 0.5 points to the right ("PR 3 as built").

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

### PR 2 as built (2026-11-11)

**What is there.**

- **The row's numbers are a value.** `ConversationRowMetrics` holds the row's sizes, spacing and fonts, and `ConversationRowPalette` its colors. `ConversationRowView` takes its metrics as a required argument, so each list names its own: `.iOS` in `ConversationListView`, `.mac` in `MacConversationSidebar`.
  - `.iOS` and the standard palette are the literals the row held, moved. `ConversationRowMetricsTests` pins every field.
  - `.mac`: a 40-point avatar, an 8-point unread dot, the name 13 points bold (`.headline` on macOS), the preview and the time 13 points regular (`.body`), no chevron.
- **The avatar takes a diameter.** `AvatarStackView(…diameter:)`, 44 points by default. Everything inside it was a literal for 44 points and now scales from that: the small avatars of a group, their offsets, the initials' font. PR 3's 40-point header avatar can pass 40.
- **The sidebar draws the selection** (decision 9). `MacSidebarRowSelectionPolicy` decides two things from one input, and the sidebar applies both:
  - The fill behind the row (`listRowBackground`, `MacSidebarRowSelectionBackground`): the system's selection color while the window appears active, whether or not the list has the keyboard focus, and the system's gray while it does not. It has the spike's geometry, 10 points in with a radius of 8.
  - The row's colors on it: on the accent color the name, the unread dot and the pin are white, and the preview and the time are white at 80% (`ConversationRowPalette.onSelectionFill`). On the gray and on no fill the row keeps its standard colors.
- **The filter button has a badge** while a filter other than All is on (`MacSidebarFilterBadgePolicy`).

**Where it differs from the plan above, or settles what the plan left open.**

- **Selected rows that touch are drawn as one shape.** The list draws them so, rounded only at the ends, and that shape is still there under the fills. With every fill rounded at all four corners, the list's gray showed at the corners between two selected rows; this was seen in the first off-screen drawing. The fill is now square at an edge it shares with another selected row (`MacSidebarRowSelectionPolicy.joins`).
- **The badge is the number 1.** `badge(_:)` on a toolbar button's menu draws a count, and zero draws nothing, so the count is the number of filters on. The spike saw such a badge drawn red.
- **The time is in the preview's font,** as on iOS. The plan gave sizes for the name and the preview only.
- **The row is 73.5 points tall** in the sidebar's list, where the iPhone's row was 80.5. The list adds 16 points on each side of the row's content, as the spike measured, and the separator starts at the text, 80 points in.
- **The initials avatar keeps its white ring.** It is the avatar's own border and the iOS list has it too. It shows in a dark window and on a selected row; Messages has none.
- **The selection drew blue, not teal.** In the app's own process (the test host) the system's selection color was `#0064E1` in a light window and `#0059D1` in a dark one. The spike's program, on this Mac, drew `#2E676B`. This Mac has no accent color set (`defaults read -g AppleAccentColor` finds no key), and the app's `AccentColor` asset is empty. The fill uses the system's color whatever it is, so nothing here depends on the answer; decision 8 may.

**Checked.**

- **iOS draws the same pixels.** A throwaway hosted test drew the row and the avatar views on the simulator (iOS 27.0), on `main` at `b52b7f3d` and on this branch: six pictures, and each pair of PNG files is byte for byte the same.
  - Rows: a mailing list, a named person, a person with no name, the generic icon, unread, pinned, an empty snippet and a name that truncates, at the default text size and at accessibility 3, light and dark.
  - Avatars: initials, the generic icon, a photo, a group's fallback initials and its empty circle, groups of two, three and four, and a group with photos.
- **The Mac row was drawn off screen** by a second throwaway hosted test, in the signed, sandboxed test host on macOS 27.2: the real `ConversationRowView` with the Mac metrics, in a real `.inset` `List(selection:)`, with the sidebar's own row background. 24 pictures: light and dark, one row selected and several, the active fill and the gray one, with the list's rows marked emphasized (as AppKit marks them when the list has the focus) and not.
  - No pixel of the list's own gray selection was left showing inside the selected rows, in any of the eight active-fill pictures.
  - An unselected row is pixel for pixel the same with the sidebar's clear row background as without it.
  - With the list's own selection and the standard colors, an emphasized row's unread dot stayed blue on the blue fill, and its pin orange. That is what the palette is for.
- **Tests.** The full iOS suite passes: 4,912 tests. `Mac.xctestplan` passes in the signed, sandboxed test host: 270 tests in 26 suites, four of them new (`ConversationRowMetricsTests`, `AvatarStackViewLayoutTests`, `MacSidebarRowSelectionPolicyTests`, `MacSidebarFilterBadgePolicyTests`).
- **Revert-checks.** Each of the 22 changes named in the new tests' `Revert-check:` comments was undone alone, and each time the test that names it failed.

**Fixed after the review of PR 387 (2026-11-12).** That review's seven findings below the one that held the merge (the sidebar did not compile under CI's Swift 6.2, fixed in the PR itself). None of it has been seen in the app.

Measured on macOS 27.2 in two more throwaway programs, each an `.inset` `List(selection:)` in a window never put on screen, and then drawn in the test host with the real row.

- **The list no longer draws a selection of its own under the fill.** The fill covered the list's selection only because the two had the same shape, and that shape was measured on one system: the app also runs on macOS 26, where nothing here was run. A list that drew another shape would show gray around the fill whenever it did not have the keyboard focus. The fill now carries an empty AppKit view (`MacSidebarListSelectionGuardView`) that finds the `NSTableView` behind the list and sets its `selectionHighlightStyle` to `.none`, so there is one selection on screen.
  - The list is an `NSTableView` (a `SwiftUIOutlineListView`), and a view in a row's `listRowBackground` is inside it, four superviews down. `layout()` is the call that found it: the view is not inside the table yet when it joins its window.
  - With the style `.none` the list drew none of its gray selection, and none of its accent-colored one with its rows marked emphasized. A selection set from SwiftUI still reached the table's selected rows. The separators next to a selected row stayed hidden. The line between two selected rows stayed, darker without the focus and lighter with it, as under the list's own selection.
  - SwiftUI never set the style back: not when a row's content changed, the selection changed or was emptied, every row was replaced, or the list was resized, scrolled, disabled, or switched between light and dark. So the guard assigns it, again at each `layout()`, and holds no observation, unlike `MacSidebarCollapseGuardView`.
  - In the test host, 16 pictures of the real row in a real list (light and dark, one row selected and three, the active fill with the rows emphasized and not, the gray fill, and a control with no fill): the table's style was `.none` in every picture with a fill, and three selected rows drew as one shape.
  - It depends on how SwiftUI builds a list on macOS 27.2. Where the guard finds no table, the list's selection is still drawn under the fill and the fill covers it where the shapes agree, which is what PR 2 had. That is why the fill keeps the list's shape and its square joins. `MacSidebarRowSelectionBackgroundTests` mounts a real list in the Mac plan, so on the system those tests run on, a change in how a list is built fails a test.
  - Until the first row is selected there is no fill, so the table still has its own style then. Whether it draws that first selection for a frame was not measured.
- **A row that is not selected has no background view.** `MacSidebarRowSelectionBackground.init` returns nil for it, and `listRowBackground` takes nil as the list's own background. Before, every row carried a clear shape.
- **The walk for the joins stops at the last selected row.** The sidebar asks for the joins at every evaluation of its body. With several rows selected that was a pass over every loaded row; now it ends where the selection does, unless a selected row is hidden by a search or a filter.
- **A group's avatar takes its disc and its rings from the row's palette** (`GroupAvatarColors`). They were literals chosen for the list's background, so in a dark window a selected group's avatar was a near-black disc with black rings on the accent color. On the accent color they are now white rings on a disc of white at 25%, the same in light and dark. On the gray fill and on no fill they are the literals, unchanged. Drawn off screen in both appearances, beside the old colors.
  - **iOS draws the same pixels.** Six pictures from a throwaway hosted test on the simulator (iOS 27.0), on `main` at `1160dd23` and with these changes: rows at the default text size and at accessibility 3, and the avatar views (initials, the generic icon, photos, groups of two, three and four, a group's fallback initials and its empty disc), each in light and dark. Each pair of PNG files is byte for byte the same.
  - The single initials avatar keeps its white ring, as before.
- **The filter button says what its badge counts.** The badge is still the number 1. The button now has the filter's name as its accessibility value and a tooltip ("Showing only: Unread"; "Filter conversations" with All). Not checked with VoiceOver: whether it reads the badge's number as well is not known.
- **Tests.** `MacConversationSidebarSourceTests` now pins that the fill is decided from the window's active state and given its joins, which nothing did. The two joins tests without a `Revert-check:` have one, or say why none exists. The full iOS suite passes: 4,927 tests. `Mac.xctestplan` passes in the signed, sandboxed test host: 292 tests in 28 suites, two of them new (`MacSidebarListSelectionGuardViewTests`, `MacSidebarRowSelectionBackgroundTests`).
- **Revert-checks.** Each of the 26 changes named in these tests' `Revert-check:` comments was undone alone, and each time the test that names it failed.

**Not seen: check in the signed, sandboxed app.**

- The sidebar with real mail, beside Messages: the row's height, spacing and text sizes. `.mac` is a first reading of a screenshot, not a measurement.
- That the open conversation stays in the accent color with the caret in the reply field, and turns gray when another app comes to the front. The off-screen window was never active, so the pictures were drawn with the fill given, not decided from the window.
- Several selected rows: one shape, with no gray between them.
- A row for a person, and a photo at 40 points. The Mac pictures are of mailing-list rows, which ask Contacts nothing; a Mac test host cannot be given Contacts access.
- The filter badge: that it appears with a filter on and goes with All, and its color. With VoiceOver on: what it reads for the button with a filter on.
- A right-click on a row that is not selected: the ring the list draws around it while the menu is open. The list's own selection is turned off now, and the measuring could not show whether the ring goes with it.
- A selected group conversation, in a light window and a dark one: the avatar's disc and rings on the accent color.
- On a Mac running macOS 26, if one is to hand: a selected row with the caret in the reply field. No gray should show around the fill.
- The sidebar's material behind the list.
- A swipe and a right-click on a row that has the fill. Their code did not change.

## PR 3: the chat header

- **Avatar and name capsule,** as the spike measured: the avatar (`AvatarStackView`, 40 points) is the `.principal` toolbar item; the capsule is the content of `safeAreaBar(edge: .top)` on the transcript, shifted 2.5 points right to sit under it. Both open Participants.
- **The bar changes the transcript's top inset** by 30 points, a constant for every chat. The reveal pass anchors at the bottom, so this should not disturb it; check a short chat (fewer rows than fill the window) and a long one.
- **Check in the app:** the glass the toolbar puts behind the avatar (`sharedBackgroundVisibility(.hidden)` if it shows), and the blur under the header.
- **Photos.** `ChatViewModel` already loads `ParticipantInfo` for the title (`ChatViewModel.swift:1400`) and keeps only the name and the count. Publish the photos and names it already has, with the same `maxParticipants: 4`, or the row and the chat fork the rollup cache (`ConversationRowView.swift:6`).
- **Click on the capsule** opens Participants, as the title does today, and not for a list conversation (`allowsParticipantListPresentation`). It stays a sheet; a popover is later polish.
- **Trailing edge:** the ⋯ menu.

### PR 3 as built (2026-11-12)

**What is there.**

- **A chat takes its header from whoever shows it.** `ChatView` has a required `headerStyle` (`ChatHeaderStyle`): `.navigationTitle` in `ConversationListView`, `.avatarOverNameCapsule(.mac)` in `MacMailboxDetail`. `ChatHeaderPolicy` says what a style means, so `ChatView`'s body holds no platform check:
  - What the toolbar's principal item is: the name, as before, or the avatar at 40 points (`ChatHeaderAvatarButton`).
  - Whether there is a name bar, and its sizes (`ChatHeaderMetrics.mac`).
  - Whether the principal item keeps the toolbar's glass (below).
  - Whether a click opens Participants: not for a mailing list, the rule the iOS title's tap already had.
- **The name is in a capsule in a bar on the transcript** (`MacChatHeaderNameBar`, put there by `View.macChatHeaderNameBar` with `safeAreaBar(edge: .top)`): the name and a chevron, on glass. The bar is 30 points tall whatever the name is, and whether a chat has one is fixed by its style, so the transcript's top inset is one number from the moment the chat mounts. `ChatMessagesView` did not change.
- **The avatar and the capsule both open Participants,** the same sheet through the same `appSheet`. For a mailing list neither is a button, and the capsule has no chevron.
- **The avatar is the row's.** `ChatHeaderPolicy.avatar` builds it from `ConversationRowPolicy`'s rules, so the header and the row cannot show different faces for one conversation.
  - `ChatViewModel` keeps the `ParticipantInfo` its title load already fetched (`participantInfo`), and asks for the row's four participants by one constant (`rollupMaxParticipants`).
  - Until that load lands the avatar is drawn from the row's entry in the rollup cache (`cachedParticipantInfo()`), so a chat opened from its row has its photo at once.
- **The trailing edge** is the chat's own ⋯ menu, as it was.

**Where it differs from the plan above, or settles what the plan left open.**

- **The avatar is taken off the toolbar's glass, and the capsule is offset 0.5 points, not 2.5.** Measured with the header's own views under a real window toolbar: a `NavigationSplitView` in a window the test host made and never showed, 900 and 1200 points wide, with a New Message button and a ⋯ menu beside the avatar.
  - Left as the toolbar draws it, the avatar's item sits inside an `NSToolbarPlatterView` holding an `NSGlassEffectView`, 40 by 40, and the drawing shows a crescent of it under the avatar. Its center is 2.5 points right of the chat column's center, the spike's number.
  - With `sharedBackgroundVisibility(.hidden)` (`ToolbarContent.macSharedBackgroundHidden`) there is no platter and no glass view, the drawing shows the avatar alone, and its center is 0.5 points right of the column's center.
  - So the two are one choice: `ChatHeaderPolicy.hidesPrincipalItemGlass` and `ChatHeaderMetrics.principalItemCenterOffset`. With both, the capsule's name and chevron drew centered 0.25 points left of the avatar's center.
- **The capsule stops 48 points short of the chat column's edges.** A name long enough would otherwise carry it to 16 points from them, and at that distance an off-screen drawing lost the transcript.
  - A glass capsule within 20 points of both edges of the scroll view under it took that scroll view's content out of the drawing. The first drawing after the view mounted had it; 14 of the 15 that followed, over a second and a half, did not. At 22 points and more it stayed.
  - The same at 520, 800 and 1100 points wide. It did not matter whether the name was truncated, whether the glass was interactive, or whether the capsule was a button. The rows' frames were the same either way, and the same bar without glass lost nothing.
  - Whether the app loses its transcript that way is not known: it has been seen neither way. `MacChatHeaderNameBarLayoutTests` pins that a name too long for the column leaves the transcript in the drawing.
- **The photo does not wait for the load.** The plan had the view model publish what its load fetched. The avatar also reads the row's cached entry until then; without it every chat opened with initials and changed to its photo a moment later.
- **The first bubble starts 90 points from the window's top:** 52 of toolbar, 30 of bar, and the transcript's own 8 points of padding. The spike's 82 is where the transcript starts.
- **`safeAreaBar` adds no spacing of its own** on macOS 27.2: the inset measured 30 points with `spacing: 0` and with no spacing given. The modifier still says 0.

**Checked.**

- **iOS draws the same pixels.** A throwaway hosted test mounted the real `ChatView` in a `NavigationStack` on the simulator (iOS 27.0) over test fixtures, and drew the whole window: the navigation bar, a four-message transcript and the reply bar. On `main` at `1160dd23` and on this branch.
  - A one-to-one chat and a mailing list, light and dark, each drawn twice: all eight PNG files are byte for byte the same as `main`'s.
  - A group, light and dark, drawn nine times each. Its title lists the participants in a different order from one mount to the next (below), so the pictures were matched by content: every order both trees drew, four light and three dark, is byte for byte the same. The pictures left over on either side were opened and are orders the other tree did not happen to draw.
- **The Mac header was drawn off screen** by a second throwaway test, in the signed, sandboxed test host on macOS 27.2: 19 pictures, light and dark.
  - The header's two views over a stand-in transcript: a person with initials, with a photo, and before any participant info; a group with and without photos; a mailing list; a name too long for the column.
  - The same views under the real window toolbar described above, with and without the toolbar's glass behind the avatar, and with a long name in a dark window.
  - The pictures were opened. They show the avatar, the name and the chevron where the measurements put them, the name truncating short of the column's edges, and no chevron for a mailing list. They draw no glass, and they cannot be trusted for the colors of anything on glass ("Not seen").
- **Tests.** The full iOS suite passes: 4,939 tests. `Mac.xctestplan` passes in the signed, sandboxed test host: 293 tests in 28 suites, two of them new (`ChatHeaderPolicyTests`, `MacChatHeaderNameBarLayoutTests`). Two more new suites run on iOS only: `ChatViewModelHeaderParticipantsTests` and `ChatHeaderStyleSourceTests`.
- **Revert-checks.** Each of the 30 changes named in the new tests' `Revert-check:` comments was made alone, 32 runs in all because one comment names three numbers, and each time the test that names it failed. Two tests did not fail at first, and were wrong, not the code:
  - The inset test claimed that deleting `spacing: 0` would fail it. It does not, as above; the test now names a change that does and says so.
  - The long-name drawing test looked at one drawing, taken at once, which still has the transcript. It now watches for a second and a half.
- **Compiled on the Mac.** The app compiled unsigned once, and that product was deleted unlaunched. The signed test host is the only Mac build that ran: sandboxed, and it never builds the mailbox.
- **The memberwise initializer CI's compiler makes private** (`CLAUDE.md`, Traps): the new views were read for a plain `private var x = value` and hold none. Only CI's own build can confirm it.

**Found, not changed here.**

- **A group's title lists its participants in whatever order a `Set` gives them** (`ConversationParticipantExtractor.extractNonMeParticipants`). The iOS drawings showed "Grace, Ada, Alan" and "Alan, Ada, Grace" for one conversation, on `main` as well. The rollup cache holds one order for five minutes; after that it can change. Fixed since, in a pull request of its own: the participants are shown in ascending order of normalized email address (`ConversationParticipantExtractor.participantsInDisplayOrder`), and the stored title is written in the same order.
- **The chat's ⋯ menu draws with a disclosure chevron beside it** on the Mac. The spike's 36-point circle was a menu with `menuIndicator(.hidden)`, which `ChatView`'s menu does not have.

**Not seen: check in the signed, sandboxed app.**

- The header beside Messages. The capsule's height (22 points), its text size (11 points, medium) and the 10 points between the avatar and the capsule are a first reading of a screenshot.
- The capsule's glass, and whether the name can be read on it in a dark window. An off-screen drawing draws no glass, and in these the name came out black in a dark window as well as a light one, while the chevron did not show in a light one. Glass picks a light or a dark look for what is on it from what is behind it, and off screen nothing is. The name and the chevron use the styles meant for glass (the default and `.secondary`), not colors by name.
- The avatar alone in the toolbar, with no glass behind it, centered over the capsule.
- The blur where the transcript scrolls under the header. With the transcript at rest the drawing shows a hairline across the column under the bar, 82 points down.
- A click on the avatar and one on the capsule: each opens Participants. In a mailing list neither does anything, and the capsule has no chevron.
- A short chat (fewer rows than fill the window) and a long one: each opens at its newest message, and nothing moves when the avatar's photo arrives.
- A conversation with a very long name: the name truncates, and the transcript is there.
- A person's photo at 40 points, and a group's. The pictures used stand-in photos; a Mac test host cannot be given Contacts access.
- VoiceOver on the header. The capsule is the control that is read; the avatar is hidden from it as a second copy of the same button.

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

### PR 4 as built (2026-11-12)

**What is there.**

- **A chat takes its bubble style from whoever shows it.** `ChatView` has a required `bubbleStyle` (`MessageBubbleStyle`): `.standard` in `ConversationListView`, the new `.mac` in `MacMailboxDetail`. It goes through `ChatMessagesView` to every `MessageBubble`. What the style means is in the style's own values and in four pure policies, so no view checks the platform.
- **Bubbles.** Radius 17, capped at half the height, so a one-line bubble is a capsule. Padding 6 and 12 points. Text at the body size, 13 points on the Mac. Incoming is an opaque gray (`systemGray5`), outgoing the system blue.
- **Tail.** `BubbleShape` draws it on the last bubble of a run, at the bottom corner on the row's own side: on the text bubble, the forwarded bubble, the loading pill and the no-preview placeholder (`MessageBubbleChrome`). The tail is drawn outside the bubble's frame, and every row keeps 4 points free on that side, so a bubble with a tail and one without line up, and so do images and cards.
- **Runs.** The stack's spacing is one constant, 2 points on the Mac and the old 8 on iOS. A row that starts a run has 8 more points above it, inside the row (`ChatTranscriptRunPolicy`). A time line breaks a run even between two messages from one sender.
- **Width.** A text bubble takes up to 65% of the transcript's width, from the `GeometryReader` the transcript already had, and never less than 280 points. The text carries that cap itself (`MessageTextWidthCap`), because the row's column is as wide as an image where an image is wider. Cards keep 280. An image is up to 400 points wide, a fixed number (`imageAttachmentMaxWidth` in the environment), and less only in a chat column under 496 points, where 400 would not fit beside the row's padding (`MessageBubbleStyle.imageMaxWidth(transcriptWidth:)`): the window's minimum leaves the column as little as 220.
- **Avatars.** None in a one-to-one chat. In a group, on the last row of an incoming run, with the sender's name above the first (`MessageBubbleRowPolicy`).
- **Time lines.** A centered line above a row whose day differs from the row before it, or that follows it by an hour or more, and above the conversation's first message (`ChatTimestampSeparatorPolicy`). The day is bold: "**Today** 2:14 PM", "**Yesterday**", the weekday for the five days before that, then the date. It is drawn inside the row (`ChatTranscriptRowLeadIn`), so the transcript's `ForEach` still holds one view per message. The row before is read with `rowForGrouping`, past the window's edge.
- **No timestamp under the bubble,** and no per-message unread dot. The exact time is the bubble's tooltip.
- **Status line.** "Sent" alone, on a line of its own under the newest sent bubble (`MessageSendStatusLinePolicy.Arrangement.captionOnly`). "Sending…", "Not sent", "Delivery unknown", "Send failed" and the badge keep their meaning and colors.
- **Large emoji.** A message of one to three emoji and nothing else is drawn at 40 points with no bubble (`ChatLargeEmojiPolicy`).

**Where it differs from the plan above, or settles what the plan left open.**

- **The row's line for "Sent" is reserved, not added.** The plan asked for no height changes after a row mounts. A caption on its own line is one, unless the line is already there. So the user's newest row has the line from its first frame, empty through the grace period, and a row with any durable status has it wherever it is (`reservesCaptionLine`). Two changes of height remain, both unanimated:
  - A newer message takes the receipt, as in Messages. The old row gives up its line, about 13 points, in the update that appends the new row.
  - A reply sent before an earlier one was accepted: the earlier row gives up its line when Gmail answers.
- **Status changes are not animated across the row on the Mac.** On iOS the row animates them, which is safe because the row's height does not change. On the Mac that animation would animate the line leaving, and with it the transcript's content size (`ChatRowEntranceEffect` says why that is a fault). The caption crossfades inside its line instead. The failed-send badge appears without a fade.
- **The tail is outside the bubble's frame,** where the spike's shape kept 4 points free inside it. The row keeps the 4 points instead, so attachments and cards line up with the bubbles too.
- **The tail's fill is a union of two paths.** As two subpaths the first drawing showed a sliver of tail beside a notched corner: the rounded rectangle and the tail wind in opposite directions, and their overlap filled as a hole.
- **The emoji rule reads the text the bubble shows,** not only the stored preview. For a row with a stored preview they are the same text from the first frame. A row without one (it shows the loading pill first) learns its form when its load lands, as it learns its text.
- **A time line also ends the run before it.** The bubble above a time line gets its tail, and in a group the row below it names its sender again.
- **The time line's label is computed when the row is drawn.** "Today" becomes "Yesterday" at the next redraw after midnight, not at midnight.

**Checked.**

- **iOS draws the same pixels.** A throwaway hosted test mounted the real `ChatView` in a `NavigationStack` on the simulator (iOS 27.0) over test fixtures and drew the whole window, on `main` at `c5457dc1` and on this branch: a one-to-one chat of ten messages (long and short text, a subject, emoji-only messages, the "Sent" receipt) and a group of seven, each in light and dark. All four pairs of PNG files are byte for byte the same.
  - Not in those pictures: the loading pill, a forwarded bubble, the no-preview placeholder, attachments, a failed send, and accessibility text sizes. Their code on iOS is the same calls in the same order, moved into `MessageBubbleChrome`.
- **The Mac transcript was drawn off screen** by the same test in the signed, sandboxed test host on macOS 27.2: the same two chats in the `.mac` style, light and dark, 520 and 900 points wide. Eight pictures, opened.
  - They show tails on the last bubble of each run and none inside a run, the time lines with the day in bold, large emoji with no bubble, "Sent" under the newest bubble, no avatar in the one-to-one chat, and in the group the avatar on a run's last row and the name above its first.
  - Text follows the width: the long incoming message is two lines at 900 points and three at 520.
- **Tests.** The full iOS suite passes: 5,007 tests. `Mac.xctestplan` passes in the signed, sandboxed test host: 369 tests in 37 suites, seven of them new to the plan (`MessageBubbleStyleTests`, `BubbleShapeTests`, `ChatTimestampSeparatorPolicyTests`, `ChatLargeEmojiPolicyTests`, `ChatTranscriptRunPolicyTests`, `MessageBubbleRowPolicyTests`, and `MessageSendStatusLinePolicyTests`, which is not new but was iOS-only). Two more new suites run on iOS only: `ChatMessageRowGroupingTests` and `ChatBubbleStyleSourceTests`.
- **Revert-checks.** Each of the 65 changes named in the new tests' `Revert-check:` comments was made alone. 63 made the test that names it fail. One does not compile, which the comment now says. One test cannot fail that way and says so (`HONEST SCOPE`: a tail of no width).
- **The memberwise initializer CI's compiler makes private** (`CLAUDE.md`, Traps): the new views hold no plain `private var x = value`. Only CI's own build can confirm it.

**Not seen: check in the signed, sandboxed app.**

- The transcript beside Messages. Every number in `.mac` is a first reading of a screenshot: the radius, the padding, the 2 and 8 points between rows, the 65%, the 400-point image, the 40-point emoji, the time line's 11-point text, the one-hour gap.
- The tail's shape, at the Mac's real scale. It was judged from drawings enlarged four times.
- The incoming gray in a dark window. It drew only a little lighter than the pane behind it; Messages' is lighter.
- Sending a reply: the row arrives with its empty line, then "Sent". Then a second reply: the first row loses its line as the second arrives. The transcript should end at its bottom both times.
- Mail arriving under your own newest message, with the transcript at its bottom and scrolled up.
- Paging up through a long chat: the first row of each loaded window keeps or lacks its time line as older rows load.
- Resizing the window over a long chat: text reflows, and the transcript keeps its place.
- A chat with images and one with a newsletter card: the image up to 400 points wide, the card at 280, both lined up with the bubbles.
- The tooltip with the exact time, on hover.
- A group: names and avatars with real contacts. The pictures used people Contacts does not know.
- A right-to-left layout was not drawn. The tail's side follows the layout direction by a tested rule.

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

- **Compile, both platforms.** The iOS build, and `DESTINATION='platform=macOS' ./Scripts/codex-build.sh --for-testing CODE_SIGNING_ALLOWED=NO`. Delete the unsigned `MushMail.app` afterwards; it is unsandboxed and must never be launched.
- **Tests.** The narrowest iOS suites while working and the full iOS suite before merge. New policy suites go into `Mac.xctestplan`, with `Revert-check:` comments.
- **Look.** Compile the real view files into the off-screen probe where they have no app dependencies (row, bubble shape, composer bar, header), render to PNG, and compare with the screenshot in light and dark.
- **Not checkable without the app:** the split view with real data, focus, menus, the mark-read gate, trackpad scrolling under the header, and window resizing over a long chat. Kevin checks those in the signed, sandboxed build, and each PR lists what was not seen.

## Risks

- **Mail marked read that nobody saw** (PR 1). The worst outcome here; it lands with the split view, not after.
- **The transcript's reveal and anchoring** were tuned on iOS inside a `NavigationStack`. PR 1 changes its container and PR 4 its row heights. Keep both changes free of post-mount height changes, and test long chats and resizing.
- **A send by accident.** Return sends mail that can't be unsent. The marked-text case is measured in the spike before PR 5 is written.
- **Two lists drifting.** The Mac sidebar and the iOS list share the view model, the row and the lifecycle modifier; only the chrome differs.
- **What the spike could not see.** Glass, a real key window and a real input method ("Not seen, and why"). Each is a named check in the PR it belongs to.
