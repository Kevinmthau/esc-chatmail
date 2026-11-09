# Plan: replace the web app with a Mac app

Written 2026-11-09 against `main` at `dce09d42`. **Decided 2026-11-09: SwiftUI on AppKit.** macOS becomes a second destination of the existing `esc-chatmail` target, instead of a Mac Catalyst build (see "Considered: Mac Catalyst"). **Status: Phase 0 is applied.** It changed project settings and added two resource files; no Swift code has changed yet. The build numbers come from test-compiling throwaway copies of the app outside the repo (Appendix B). Those builds were never launched, and they have been deleted.

## Summary

- **One target, two platforms.** Add plain **Mac** (not Catalyst, not "Designed for iPad") as a destination of the `esc-chatmail` target, with macOS 26 as the minimum.
  - New files reach both platforms automatically through the filesystem-synchronized groups.
  - The account boundary, sync, send and persistence code is shared as it is.
- **The port is measured.** Test-compiling the app for macOS fails in 85 of 495 files, with 484 distinct errors. That count is a floor: fixing the first round of errors will reveal more.
  - Views have most of the failures: 49 of 94 files.
  - `Services/` has failures in 28 of its 359 files. In Sync, Send and Security, the only errors are a Contacts call, the send's background-time lease, and the type used to present sign-in.
  - All 17 view models compile unchanged.
- **WebKit is the biggest risk.** On macOS, `WKWebView` has no `scrollView`. The inline previews, the snapshot renderer and the full reader rely on iOS-only WebKit API, about 90 errors in all. Build a prototype first.
- **App behavior needs Mac rules, not just compile fixes.** iOS-specific behavior:
  - Sync stops whenever the scene goes to the background.
  - Database maintenance runs as BGTasks, which don't exist on macOS.
  - Sends hold background-time leases.

  A Mac app instead stays open all day, gets quit with Cmd-Q, and sleeps when the lid closes.
- **Hard safety rule: the Mac build is sandboxed from its very first launch.** Fresh-install and sign-out cleanup (`FreshInstallHandler.clearAttachmentFiles`, `AuthSession.deleteAttachmentFilesFromDisk`) delete:
  - `Documents/Messages` and `Documents/Attachments`
  - the `Attachments` and `Previews` folders under Application Support

  Inside the sandbox those paths are in the app's own container. In an unsandboxed build they are your real `~/Documents` and the shared `~/Library/Application Support`.
- **Retire `web/` last,** after about two weeks of using the Mac app every day. Take down the Netlify site, the DNS record and the web OAuth client before deleting the code.

## What the web app is today

| Piece | Where | At retirement |
|---|---|---|
| The PWA | `web/`: 316 tracked files, about 64k lines of TypeScript including tests | Delete |
| Web CI | `.github/workflows/web.yml`, plus the `paths-ignore` entries on `ci.yml` lines 10 and 13 | Delete the workflow and the two lines |
| Hosting | Netlify site `mushpot-mail` at https://mail.mushpot.net. Its base directory (`web`) is set in Netlify's UI. Every push to `main` that touches `web/` deploys | Delete the site and the DNS record |
| OAuth | Web client `esc-chatmail-web` in Google Cloud project `esc-gmail-client`. Origins: `localhost:5173`, `127.0.0.1:5173`, `https://mail.mushpot.net` | Delete the client |
| Mail stored in browsers | One IndexedDB database per account plus a service-worker cache, in every browser you used | Sign out and clear site data |
| Dev tooling | `.claude/launch.json`, whose only configuration is `web` | Delete |
| Docs | `CLAUDE.md` lines 3, 19–26, 33, 42 and 131–132; the two "From `web/`" blocks in `README_GOLDEN_CORPUS.md`; the web items in `docs/scalability-review.md` | Edit |

Keep these, even though a search for "web" or "netlify" finds them:

- `NetlifyDeployPreviewBuilder`, `NetlifyDeployPreviewCard` and their tests. They render the iOS preview card for emails from the Netlify bot; they have nothing to do with hosting.
- `golden_message_corpus.json`. `GoldenCorpusReplayTests` replays it on iOS. It is the only fixture the web app imports.
- `Configuration/{Debug,Release}.xcconfig`. CLAUDE.md line 132 covers them in the same sentence as the web `.env` files.

The parity bar is what the web app does that iOS doesn't, beyond running on a desktop:

- **A From: alias picker in compose** (`web/src/features/compose/AliasPicker.tsx`). It appears when the account has more than one alias it can send from. iOS compose has no equivalent.
- **Desktop input:**
  - Enter sends, and Shift-Enter adds a new line.
  - In selection mode, arrow keys move through the list and Escape leaves it.
  - Arrow keys page through the attachment lightbox.
  - Right-click opens menus.

Everything else in `web/src/features` already exists on iOS: search, filters, row and batch actions, drafts, auto-mark-read, forward, attachments, the full reader and calendar invites.

## Decisions

Already decided: SwiftUI on AppKit (2026-11-09). Still open:

1. **Minimum macOS version: 26 (recommended).**
   - At a macOS 15 minimum, the only availability errors are three Liquid Glass calls (`safeAreaBar`, `glassEffect`, `GlassEffectContainer`) in `View+ConversationListChrome.swift`. iOS already gates them behind iOS 26.
   - At 26 those calls compile unchanged, and SwiftUI's own `WebView`/`WebPage` (macOS 26 and later) becomes an option for the WebKit work.
   - This Mac runs macOS 27.
2. **Keep the bundle ID `com.esc.inboxchat` (recommended).** A target that builds for several platforms shares one bundle ID by default. Google's docs say macOS apps use an iOS-type OAuth client keyed by bundle ID, so the existing client and its URL scheme should work unchanged.
3. **Distribution.**
   - TestFlight for Mac: the app updates itself. The app already sets `ITSAppUsesNonExemptEncryption`, which suggests it is uploaded to App Store Connect.
   - Or a Developer ID-signed, notarized `.app` that you update by hand.
4. **When to delete `web/`.** Recommended: after Phase 3. Stop adding web features now, and fix the web app only if it breaks.
5. **The From: alias picker on the Mac.** If you use it on the web, it belongs in Phase 3. iOS gets it too, because the platforms share views.

Before Phase 0 there was a stopgap: Xcode listed *My Mac (Designed for iPad)*, which ran the unmodified iOS app in a window. Xcode drops that destination once a target supports macOS natively, so the stopgap went away with Phase 0.

## Phase 0: project setup (done 2026-11-09)

A session applied this phase with explicit permission to edit `project.pbxproj`; CLAUDE.md otherwise forbids hand-editing it. Every Mac-only setting on the `esc-chatmail` target is scoped with `[sdk=macosx*]`. The test target is untouched and stays iOS-only until PR F.

- **Mac destination.** `SUPPORTED_PLATFORMS` gains `macosx`, with `SDKROOT = auto`, `SUPPORTS_MACCATALYST = NO` and `MACOSX_DEPLOYMENT_TARGET = 26.0`. Xcode now lists *My Mac* and *Any Mac*.
- **Info.plist.** `INFOPLIST_FILE[sdk=macosx*]` points at `esc-chatmail/Resources/Info-macOS.plist`. Like `Info.plist`, it is kept out of the target's bundled resources through the synchronized group's membership exceptions.
  - **It contains:**
    - the `CFBundle*` keys, including the `GOOGLE_REDIRECT_URI` URL scheme
    - the `GOOGLE_*` keys that `GoogleConfig` reads (`Constants.swift:24`)
    - `NSAppTransportSecurity`, `NSContactsUsageDescription`, `ITSAppUsesNonExemptEncryption`, `LSApplicationCategoryType` and `LSMinimumSystemVersion`
  - **It leaves out the iOS-only keys:** `BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes`, `UILaunchScreen`, `UIApplicationSceneManifest`, the orientation keys, `UIRequiredDeviceCapabilities`, `LSRequiresIPhoneOS` and `LSApplicationQueriesSchemes`.
- **Sandbox.** The sandbox comes from the target's App Sandbox build settings, which is where Xcode's capability editor keeps them.
  - `ENABLE_APP_SANDBOX = YES` was already set. Phase 0 added macOS-scoped `ENABLE_OUTGOING_NETWORK_CONNECTIONS`, `ENABLE_RESOURCE_ACCESS_CONTACTS`, `ENABLE_USER_SELECTED_FILES = readwrite` and `ENABLE_HARDENED_RUNTIME`.
  - These settings look like leftovers in an iOS project, but they are what sandboxes the Mac build. **Never remove them.**
- **Entitlements.** `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` points at `esc-chatmail/Resources/esc_chatmail-macOS.entitlements`. That file holds only `keychain-access-groups` = `$(AppIdentifierPrefix)com.esc.inboxchat`, which GoogleSignIn's README requires on macOS.
  - There is no push entitlement. Nothing in the app registers for remote notifications (there is no `registerForRemoteNotifications` or `UNUserNotificationCenter` anywhere), so the iOS `aps-environment` entitlement is unused.
- **Runpath.** `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]` is `@executable_path/../Frameworks`, the location of frameworks in a Mac app bundle.

**Checked:**

- **iOS settings unchanged.** For both targets, I compared every iOS build setting before and after, in Debug and Release, for simulator and device. The only changes are `SUPPORTED_PLATFORMS` and `MACOSX_DEPLOYMENT_TARGET`, which iOS builds ignore. The test target's settings are identical.
- **iOS build.** The iOS simulator build succeeds with no app warnings.
- **Mac build.** The Mac build compiles every package for macOS without errors: AppAuth, AppCheckCore, Promises, GTMAppAuth, GTMSessionFetcher, GoogleSignIn, GoogleUtilities and SwiftSoup. It also compiles the app's asset catalog. It then stops at the first `import UIKit` with `Unable to resolve module dependency: 'UIKit'`, which is where Phase 1 starts.
- **Mac plist variables.** All 12 variables in `Info-macOS.plist` resolve in the macOS build settings.

**Not checked yet:**

- **A signed Mac build and its real entitlements.** The first time, Xcode's automatic signing may need to register this Mac with the team and create a Mac development profile. Check the entitlements then with `codesign -d --entitlements - <app>`.
- **The processed Mac `Info.plist`.** The failed build stops before that step.

The Mac build stays red until Phase 1 lands, and nobody launches it before PR C.

## Phase 1: compile and run on macOS

**Goal:** the Mac build launches, signs in, syncs, opens a chat, sends a reply and archives, with the iPhone-shaped UI in a window. iOS behavior doesn't change, and the full iOS suite stays green after every PR.

**Rules for every Phase 1 PR:**

- **Prefer APIs that exist on both platforms over `#if`:** `.fileImporter`, `.fileExporter`, `.quickLookPreview`, `PhotosPicker`, `openURL`, `.alert`, and toolbar placements that work on both.
- **Put the remaining platform splits in a new `esc-chatmail/Platform/` folder,** one type per file (house style), instead of scattering `#if` through views.
- **Exclude iOS-only files by wrapping the whole file in `#if os(iOS)`.** Per-platform file membership would mean editing the project file.
- **Keep both platforms free of warnings** (`SWIFT_TREAT_WARNINGS_AS_ERRORS` applies to both).
- **Leave the CLAUDE.md contracts unchanged:** the account-boundary order, the sync cursor, the send barrier. The Mac work adds platform adapters underneath them.

**Order:**

1. Run the WebKit spike first. It can run alongside PR A.
2. Land PR A next.
3. Run B, D and E in parallel sessions; they touch separate files.
4. C shares `AuthSession.swift` with D. It is small, so land it first, or do C and D in one session.
5. PR C must land before any Mac build is launched.
6. F goes last.

**WebKit spike (1–2 days, throwaway branch).**

- Render a chat that has an HTML preview card on macOS, scroll past the card with a trackpad, and open the full reader.
- Compare a `WKWebView` wrapped in `NSViewRepresentable` with SwiftUI's `WebView`/`WebPage` (macOS 26 and later).
- The result decides how PR E is built.

**PR A: image and color shims (do first; the others build on it).** About 115 errors: `UIImage` 83, `UIColor` 26, `UIGraphics` 6.

- They are mostly in `Services/Caching` (9 files, 65 errors), `Services/Utilities/ImageProcessor.swift` and `ImageUtilities.swift`, the avatar and attachment views, and `Utilities/UIColor+Hex.swift`.
- Add `PlatformImage` and `PlatformColor` typealiases with the few members the code uses, and draw with Core Graphics or ImageIO instead of `UIGraphicsBeginImageContext`.
- Give the system colors (`secondarySystemBackground` and the like) a `Color` extension.
- Add the imports that some files currently get through UIKit (Foundation, Combine, CoreGraphics). Several "cannot find type `CGSize`/`Data`/`ObservableObject`" errors are only that.

**PR B: app lifecycle and background work.** This covers 45 errors in `Services/Background`, plus the send lease, the app entry point and the memory-warning observer.

- **BGTasks.** `BGTaskScheduler` and every `BG*Task` type are `API_UNAVAILABLE(macos)` (checked in the macOS 27.2 SDK headers).
  - Put the BGTask layer behind `#if os(iOS)`.
  - Give `BackgroundTaskScheduling`, which is already a protocol, an `NSBackgroundActivityScheduler` implementation for the three database-maintenance jobs (vacuum, analyze, cleanup).
- **When sync runs.** Today a `.background` scene phase stops foreground sync and schedules the BGTasks (`handleScenePhaseChange` in `esc_chatmailApp.swift`). On the Mac:
  - Start the foreground sync session when `initializeApp()` finishes, and keep it running until the app quits.
  - Sync immediately when the app becomes active and when the Mac wakes.
  - Pause while the system sleeps, using the `NSWorkspace` sleep and wake notifications.
  - Don't let a minimized or hidden window's scene phase stop sync.

  `ForegroundSyncCoordinator` already syncs every 60 s with a 30 s minimum gap, the same cadence as the web scheduler.
- **Background-time leases.** `OutboundSendBackgroundLease` and `SceneBackgroundAssertionLatch` wrap `UIApplication.beginBackgroundTask`. macOS doesn't suspend apps, so on the Mac the lease becomes a `ProcessInfo.beginActivity`, which keeps App Nap and idle sleep from stalling a send, with no expiration.
  - That means `backgroundTimeExpiredWithoutTeardown` never fires on macOS.
  - Don't add a Mac substitute that rolls sends back.
- **Quitting.** In `applicationShouldTerminate`, answer `.terminateLater` while an outbound send is between reservation and outcome. Wait at most about 10 s, then let the app quit. A forced quit is still safe, because cold recovery converts the markers and never resends.
- **Smaller pieces:**
  - Replace `@UIApplicationDelegateAdaptor` with `@NSApplicationDelegateAdaptor`.
  - The `UIApplication.shared.applicationState` check in `initializeApp()` treats the Mac as always in the foreground.
  - `MemoryWarningObserver` switches to `DispatchSource.makeMemoryPressureSource`.

**PR C: keychain and the sandbox tripwire.** It is small, but it decides whether sign-in survives a relaunch and whether a misconfigured build can delete files.

- **Keychain flag.** `KeychainService.baseQuery` doesn't set `kSecUseDataProtectionKeychain`. On macOS that sends tokens to the older file-based keychain, where the `kSecAttrAccessible…` levels the service uses don't apply.
  - Add the flag. `GoogleSignInKeychainProbe` (`AuthSession.swift:24`) already passes it on iOS.
  - Without both the flag and the access-group entitlement from Phase 0, sign-in appears to work but the session is gone after a relaunch.
- **Sandbox tripwire.** On macOS, the two cleanup functions named in the summary refuse to run unless the process is in a sandbox container (for example, `APP_SANDBOX_CONTAINER_ID` is set), and log loudly when they refuse.
- **Tests** for both, with `Revert-check:` comments per house style.

**PR D: presenting views, sign-in, contacts and small SwiftUI fixes.**

- **Sign-in.** These files look up a `UIViewController` or `UIWindow` to present sign-in:
  - `AuthSession` (4 errors)
  - `TopPresentableViewController` (21)
  - `SignInView` (6)
  - `ContentView`

  Add a `PresentationAnchor` type: `UIViewController` on iOS, `NSWindow` on macOS. GoogleSignIn takes a window on macOS. Sign-in opens the browser and returns through the existing URL scheme and `onOpenURL` handler.
- **Alerts, Quick Look and file picking.**
  - `SettingsAppSignOutPrompter` (`UIAlertController`) becomes `.alert`.
  - `QuickLookPreviewController` (13 errors) becomes `.quickLookPreview`.
  - The document picker in `AttachmentPicker` (11 errors) becomes `.fileImporter`.
- **Contacts.**
  - `EditContactView`, `AddContactView` and `ContactPickerView` (35 errors) use iOS-only ContactsUI. On the Mac, compile them out and offer "Open in Contacts" instead.
  - The `.limited` authorization status (6 places) and `.contactAccessPicker` (`ChatView`) are iOS-only.
  - The repo's only existing `#if os(macOS)` code is in `ContactsSelfAliasProvider.swift`, and its block at lines 41–45 has never compiled. The macOS method name is `unifiedMeContactWithKeys(toFetch:)`.
- **iPhone keyboard and screen code.** `KeyboardResponder` (8 errors) and the `UIScreen` sizing (7) are compiled out or replaced with geometry.
- **iOS-only SwiftUI modifiers (about 8).**
  - Toolbar placements: `topBarLeading`, `topBarTrailing` and `navigationBarTrailing` become `.navigation` or `.primaryAction`.
  - `navigationBarTitleDisplayMode` and `textInputAutocapitalization` stay iOS-only.

**PR E: WebKit (about 90 errors).** The spike decides the approach.

- **Where:**
  - `FullEmailWebViewManager` (36 errors)
  - `BaseEmailWebView` (14)
  - `HTMLRenderingDebugView` (14), which can stay iOS-only
  - `EmailPreviewSnapshotRenderer` (12)
  - `FullEmailReaderWebView` (10)
  - the snapshot view and the mini web view
- **iOS-only API in use:**
  - `WKWebView.scrollView` (12 errors)
  - `overrideUserInterfaceStyle`, `backgroundColor` and `isUserInteractionEnabled`
  - `layoutSubviews` and `didMoveToWindow` overrides
  - `dataDetectorTypes` and `allowsInlineMediaPlayback`
  - `UIViewRepresentable` and UIGraphics snapshots
- **Mac equivalents:**
  - Wrap the web view in `NSViewRepresentable`.
  - Inline web views, which don't scroll themselves, pass trackpad scrolling (`scrollWheel`) to the transcript and size themselves from a height measured in JavaScript.
  - Set dark or light mode through `NSAppearance` and transparency through `underPageBackgroundColor`.
  - `takeSnapshot` returns an `NSImage`.
- **What to test:**
  - AGENTS.md warns that changes to snapshot sizing and to `MiniEmailWebView`'s fallback height can destabilize chat scrolling.
  - The transcript's check for when to reveal the newest message (`ChatTranscriptRealizationPolicy`) was tuned on iOS.
  - So test long chats and window resizing on the Mac.

**PR F: tooling, CI and Mac tests.**

- **Local commands.** `DESTINATION='platform=macOS' ./Scripts/codex-build.sh` and `./Scripts/codex-test.sh` work as soon as the target supports macOS, because both scripts pass an explicit `DESTINATION` through. Document this in CLAUDE.md.
- **CI.** Add a "Build (macOS)" job to `ci.yml` that builds unsigned (`CODE_SIGNING_ALLOWED=NO`) and runs no tests. A comment in `ci.yml` notes that macOS runner minutes bill at 10x.
- **Mac tests.** Add macOS to the test target in Xcode.
  - 32 of the 317 test files use UIKit or BGTask types and need `#if os(iOS)`.
  - A small `Mac.xctestplan` runs PR C's tests, the lifecycle policy, the shims, and the boundary and cursor suites (`AuthSessionTests`, `HTMLContentAccountBoundaryTests`, `IncrementalSyncCursorTests`). It shows that `Services/` behaves the same on macOS. The full suite stays on iOS.
- **Two constraints on Mac tests:**
  - **Contacts.** Nothing can grant Contacts access to a Mac test host ahead of time, the way `prepare-simulator.sh` does on iOS. The Mac plan must keep away from the real Contacts store by injecting `accessRequester`, as CLAUDE.md already asks.
  - **Signing.** On macOS, the `keychain-access-groups` entitlement must be backed by a provisioning profile, so running Mac tests in CI means setting up signing there. Until then, run the Mac test plan locally.

**Phase 1 is done when** all of the following work on the Mac: sign in, initial sync, open a chat, send a reply, archive, sign out and sign back in. The iOS suite stays green, and the Mac CI build is green.

## Phase 2: make it a Mac app

- **Windows.** Show the main UI in a single window. Use either a `Window` scene, or a `WindowGroup` where `CommandGroup(replacing: .newItem)` turns File → New Window into New Message (Cmd-N).
  - Why one window: `ChatReplyComposerDirectory` lets only the most recently shown composer write a conversation's draft, so two windows on the same chat would fight over its draft.
  - Revisit multiple windows after reviewing that rule.
- **Layout.** On the Mac, use a `NavigationSplitView`: the conversation list (search and filters) in the sidebar, the chat in the detail column. Branch at the root view.
  - Keep the iPhone's `NavigationStack` as it is. The transcript's anchoring and reveal logic was tuned inside it.
- **Settings.** A `Settings` scene replaces `Settings.bundle`, which has three rows: account email, a Sign Out toggle, and the version.
  - Sign Out calls the existing `AuthSession.signOut`. Don't add a seventh AuthSession path.
- **Menus and shortcuts:**
  - Cmd-N new message, Cmd-R sync now, Cmd-F search.
  - Delete archives; Cmd-Shift-U toggles unread.
  - Space opens Quick Look on an attachment; Escape leaves selection.
  - Return sends; Option-Return or Shift-Return adds a new line (`.onKeyPress`).
- **Toolbar.** New message, sync and search go in the window toolbar.
- **Selection.**
  - `List(selection:)` with Shift-click and Cmd-click drives the existing selection service and batch actions.
  - Rows and message bubbles get right-click menus.
- **Files.**
  - Drop files into the composer, through the existing draft-attachment import.
  - Drag attachments out of a message.
  - Add Save Attachment… (`fileExporter`).
  - Open attachments in their default app (`NSWorkspace`).
- **Closing the window.** Decide whether the app keeps running and syncing like Mail, where clicking the Dock icon reopens the window, or quits. Either way, sync follows the app's lifetime, not the window's.
- **Name and icon.** The Mac bundle and its menu name still come from the target name (`esc-chatmail`). `AppIcon` has only the iOS 1024-pixel image, so the Mac app shows a generic icon. Give the Mac build the MushMail name and a macOS icon.
- **Optional:**
  - An unread count on the Dock icon or in a `MenuBarExtra`.
  - New-mail notifications. Neither iOS nor the web app has them today.
  - Printing.

## Phase 3: parity, then daily use

- **Close the parity gaps:** the From: alias picker if decision 5 says yes, and the desktop input behaviors.
- **Re-rank the iOS items in `docs/scalability-review.md`.** They now apply to the Mac too, and a desktop app that stays open all day runs the 60 s sync loop for hours.
- **Use the Mac app as your only desktop mail client for about two weeks.** Leave the web app online but unused.

## Phase 4: retire the web app

Do these steps in order. Everything before the DNS and OAuth deletions can be undone.

1. **Erase the copies of your mail stored in browsers.** In every browser where you used mail.mushpot.net or `localhost:5173`:
   - Sign out first. Sign-out deletes every per-account IndexedDB database (`deleteAccountDB` in `web/src/db/schema.ts`).
   - Then clear the site's data, which removes the service-worker cache.
   - Uninstall the PWA if you installed it.
2. **Delete the Netlify site `mushpot-mail`,** before or together with the repo PR.
   - If you only delete `web/`, the next push to `main` starts a Netlify build that fails.
   - A failed build leaves the last deploy published, so the old app would stay live.
3. **Remove the `mail.mushpot.net` DNS record.**
4. **Delete the `esc-chatmail-web` OAuth client** in Google Cloud, or at least remove its `https://mail.mushpot.net` origin.
   - While the origin stays registered, whoever controls that hostname next can request access through your app's consent screen.
   - Keep the iOS client, because the Mac app uses it.
5. **Open a repo PR, "Retire the web app".**
   - Delete `web/`, `.github/workflows/web.yml` and `.claude/launch.json`, and remove the `paths-ignore` lines from `ci.yml`.
   - In `CLAUDE.md`:
     - Rewrite line 3.
     - Remove lines 19–26 (web commands), 33 (web CI), 42 (web layout) and 131 (the web end-to-end test trap).
     - On line 132, keep the part about the `.xcconfig` files.
     - Add the Mac build and test commands, and the Mac rules: sandbox tripwire, Mac lifecycle, `Platform/` folder.
   - Remove the "From `web/`" blocks from `README_GOLDEN_CORPUS.md`.
   - Mark the web items in `docs/scalability-review.md` as retired instead of deleting them.
6. **Update agent memory.** Delete or rewrite the memories about:
   - the web deploy
   - running web commands through corepack
   - the web review fixes
   - the web source file that grep treats as binary

## Risks

- **An unsandboxed Mac build deletes real files.** PR C's tripwire lands before the first launch.
- **WebKit on macOS.** The spike comes first. If it goes badly, Mac Catalyst is the fallback (see below).
- **iOS lifecycle assumptions are wrong on a desktop.** Suspension, background-time expiry and BGTasks don't behave the same on a Mac. The account-boundary order in `AuthSession` stays exactly as it is; only the events that trigger it change.
- **Sign-in doesn't persist.** Without both the keychain flag and the access group, sign-in appears to work but the session is gone after a relaunch.
- **An ongoing cost.** Every future UIKit call on iOS needs a Mac counterpart. The Mac CI build catches the misses.
- **No access from non-Apple devices.** After Phase 4, Gmail itself is the only way to read this mail on a non-Apple computer or phone.

## Considered: Mac Catalyst

- **The measurement.** A Catalyst build of the same code failed on exactly one line (`.contactAccessPicker` in `ChatView.swift`). Once that line was guarded, it built and linked with no warnings.
- **What it avoids.**
  - Catalyst keeps UIKit's `WKWebView`, which has `scrollView`, so the WebKit, image, contacts and BGTask code would compile unchanged.
  - Catalyst would show `Settings.bundle` as the Mac Settings window.
- **What it gives up.**
  - It is UIKit on the Mac.
  - It lacks the AppKit-only SwiftUI scenes (`Settings`, `MenuBarExtra`) and AppKit's lists and menus.
- **Status: not chosen (2026-11-09).** It remains the fallback if the WebKit spike fails badly. The Phase 2 work (`NavigationSplitView`, `.commands`, `.keyboardShortcut`, `.contextMenu`, `.onKeyPress`) uses SwiftUI APIs that Catalyst also has, so that work would carry over.

## Appendix A: where the 484 errors are

| Area | Errors | Files with errors |
|---|---|---|
| Views | 237 | 49 of 94 |
| Services | 201 | 28 of 359 |
| Utilities | 30 | 3 of 6 |
| App | 15 | 4 of 14 |
| Models | 1 | 1 of 5 |
| ViewModels | 0 | 0 of 17 |

The biggest single files are:

- `FullEmailWebViewManager` (36)
- `AttachmentCacheActor` (25)
- `TopPresentableViewController` (21)
- `BackgroundTaskScheduler` (19)
- `EditContactView` and `AttachmentThumbnailLoader` (18 each)
- `BackgroundTaskRegistry` (16)

## Appendix B: how the numbers were measured

- **Isolation.** `git archive HEAD` exported a copy into a scratch folder, so nothing in the repo or its DerivedData was touched.
- **macOS probe.**
  - The 37 `import UIKit` lines were wrapped in `#if canImport(UIKit)`, so the compiler reports each UIKit use instead of stopping at the import.
  - The project SDK was switched to `macosx` with a deployment target of 15.0.
  - Whole-module type-checking made every file report its errors.
  - With a 26.0 minimum, the three Liquid Glass errors in `View+ConversationListChrome.swift` disappear.
- **Catalyst probe.** The copy set `SUPPORTS_MACCATALYST = YES` and was otherwise unchanged. It produced one error, then built and linked once that line was guarded.
- **The counts are floors.** The type-checker skips code that depends on a broken declaration, so fixing the first round of errors will reveal more.
- **Never launched.** The builds were unsigned and unsandboxed, the exact configuration the sandbox rule forbids. They were never launched, and they have been deleted.
