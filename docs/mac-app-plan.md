# Plan: replace the web app with a Mac app

Written 2026-11-09 against `main` at `dce09d42`. **Decided 2026-11-09: SwiftUI on AppKit.** macOS becomes a second destination of the existing `esc-chatmail` target, instead of a Mac Catalyst build (see "Considered: Mac Catalyst"). **Status (2026-11-10): Phase 0 is applied, and every Phase 1 PR is merged.** The Mac app was first launched on 2026-11-10, signed and sandboxed. Sign-in, initial sync and opening a chat worked; the rest of Phase 1's check is still to walk (see "First launch"). Phase 2 is partly built: each of its entries says what is (2026-11-12). Phases 3 and 4 have not started. The error counts in this plan were measured before Phase 1, by test-compiling throwaway copies of the app outside the repo (Appendix B). Those builds were never launched, and they have been deleted.

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

- **A From: alias picker in compose** (`web/src/features/compose/AliasPicker.tsx`). It appears when the account has more than one alias it can send from. iOS compose has no equivalent, and the Mac will not get one (decision 5).
- **Desktop input:**
  - Enter sends, and Shift-Enter adds a new line.
  - In selection mode, arrow keys move through the list and Escape leaves it.
  - Arrow keys page through the attachment lightbox.
  - Right-click opens menus.

Everything else in `web/src/features` already exists on iOS: search, filters, row and batch actions, drafts, auto-mark-read, forward, attachments, the full reader and calendar invites.

## Decisions

Already decided: SwiftUI on AppKit (2026-11-09). Items 1 and 2 are decided and applied (Phase 0, 2026-11-09). Kevin decided items 3 and 5 to 8 on 2026-11-11. Item 4 is still open.

1. **Minimum macOS version: 26. Decided and applied.** Phase 0 set `MACOSX_DEPLOYMENT_TARGET = 26.0`, and the processed Mac `Info.plist` has `LSMinimumSystemVersion` 26.0. The reasons:
   - At a macOS 15 minimum, the only availability errors are three Liquid Glass calls (`safeAreaBar`, `glassEffect`, `GlassEffectContainer`) in `View+ConversationListChrome.swift`. iOS already gates them behind iOS 26.
   - At 26 those calls compile unchanged, and SwiftUI's own `WebView`/`WebPage` (macOS 26 and later) becomes an option for the WebKit work.
   - This Mac runs macOS 27.
2. **The bundle ID stays `com.esc.inboxchat`. Decided and applied.** The Mac build is signed under it, with its own Mac profile (see "Not checked in Phase 0, checked 2026-11-10"). A target that builds for several platforms shares one bundle ID by default. Google's docs say macOS apps use an iOS-type OAuth client keyed by bundle ID; the Mac plist takes the same `GOOGLE_*` build settings as the iOS one, and sign-in worked at the first launch.
3. **Distribution: TestFlight for Mac. Decided 2026-11-11.** The app updates itself, and the Mac build goes on the App Store Connect record the iOS app already has, because the two share a bundle ID. The alternative was a Developer ID-signed, notarized `.app` updated by hand. Nothing has been uploaded yet.
   - **In place:**
     - The App Sandbox and the hardened runtime on the target.
     - In `Info-macOS.plist`: the category (`public.app-category.productivity`), `ITSAppUsesNonExemptEncryption` and the MushMail display name.
     - A macOS icon and the MushMail bundle name, since 2026-11-11. See "Name and icon" in Phase 2.
   - **A Release archive builds from the command line.** Checked 2026-11-11 with Xcode 27.2, without `-allowProvisioningUpdates`, before the rename and again after it: `xcodebuild archive -project esc-chatmail.xcodeproj -scheme esc-chatmail -configuration Release -destination 'generic/platform=macOS' -archivePath <path>` ended in `ARCHIVE SUCCEEDED`. Read from the second archive, which was then deleted and never launched:
     - The app is `MushMail.app`, with a `MushMail.app.dSYM`. The archive's own name is still the scheme's, `esc-chatmail`.
     - It is universal (`x86_64` and `arm64`). The first archive's two slices were both built for macOS 26.0.
     - It is signed "Apple Development" with the Mac team profile, and `codesign --verify --deep --strict` passes. The signature has the hardened runtime and the five entitlements of the Debug build listed under Phase 0, the App Sandbox among them, and no `get-task-allow`.
     - It has the icon: both icon keys in `Info.plist`, and in the first archive `AppIcon.icns`, `Assets.car` and `PrivacyInfo.xcprivacy` were listed in its resources.
     - Its version is 1.0 (1), from the project.
     - `Scripts/verify-mac-test-host.sh` passes on it, which is that script reading the renamed bundle, not a test run.
   - **Missing for an upload, on this Mac:** an Apple Distribution certificate, a Mac installer certificate and a Mac App Store profile for `com.esc.inboxchat`. The keychain has one signing identity, Apple Development, and the only Mac profile for the app is the development one. Nobody exported or uploaded the archive, so whether App Store Connect accepts the build has not been tried.
   - **How iOS builds are numbered and uploaded: Xcode Cloud does it.** That is Kevin's answer (2026-11-11). What the repository and GitHub show agrees with it:
     - The project says `CURRENT_PROJECT_VERSION = 1`, the installed iOS TestFlight build is 1.0 (513), and the repo has no upload tooling. So the project's number is not the one that ships.
     - An Xcode Cloud workflow named Default runs an "Archive - iOS" action on pushes to `main`: its check run is on four of the six merge commits on `main` from PR 376's to PR 381's (2026-11-09 to 2026-11-11), PR 381's merge among them. The checks PR 381 had before it merged include no Xcode Cloud run, which suggests the workflow does not run on pull requests. This Mac has no Xcode archive of any app.
     - Merging a pull request to `main` is therefore what starts an iOS build.
     - The keychain on this Mac has no iOS distribution certificate either, so that route signs somewhere else.
     - For the Mac: an archive made on this Mac, in Xcode or with `xcodebuild`, is 1.0 (1).
   - **Xcode Cloud builds the Mac app too, since 2026-11-11.** Kevin added the macOS platform to the app's record in App Store Connect and asked for the Mac build to go up the way iOS does. The Default workflow was edited in App Store Connect that day; it lives there, not in the repo. It now has:
     - **"Archive - macOS":** platform macOS, scheme `esc-chatmail`, built for Any Mac, distribution preparation "TestFlight (Internal Testing Only)". Apart from the platform these are the settings of "Archive - iOS", which is unchanged.
     - **"TestFlight Internal Testing - macOS":** it delivers the macOS archive to the Team group, the one group the iOS post-action delivers to.
     - **Unchanged:** the start condition (any file change on `main`, with a newer push cancelling a running build) and the environment (the latest release of Xcode and of macOS, which was Xcode 27.2 on macOS 27.2 that day).
     - **Not seen yet: a Mac build.** The first one starts with the next push to `main`. Still to be seen: that Xcode Cloud's signing covers the Mac entitlements, `keychain-access-groups` among them; that App Store Connect accepts the build; and what build number it gets.
     - The other way, not taken: archive in Xcode for Any Mac and use Distribute App, which would have Xcode create the profile and the two certificates above.
   - **Kevin's steps left:** install the Mac build from TestFlight once one is there, and say what should happen to the copy described next.
   - **To settle:** what happens to `/Applications/MushMail.app` on this Mac. It is the iOS TestFlight build, running as an iPhone app, under the same bundle ID and in the same container. Since the rename the native build has the same file name too. Whether TestFlight replaces it with the native build has not been seen.
4. **When to delete `web/`.** Recommended: after Phase 3. Stop adding web features now, and fix the web app only if it breaks.
5. **The From: alias picker: not built. Decided 2026-11-11.** Kevin asked for whichever option was simpler, and that is no picker on either platform.
   - The Mac sends as iOS does today. A new message goes out from the signed-in Gmail address. A reply goes out from the send-as alias the mail was addressed to (`ReplyFromAddressResolver`).
   - The picker is the one web feature that goes away with `web/`. Revisit it only if the two weeks of daily use in Phase 3 show it is missed.
6. **Older mail: none. Decided 2026-11-11.** A new Mac install starts at the install time, as iOS does, with about five minutes of mail. Nothing loads older mail.
7. **Closing the window quits the app. Decided 2026-11-11.** The alternative was to keep running and syncing like Mail. See "Closing the window" in Phase 2.
8. **The first click in an inactive window only activates it. Decided 2026-11-11.** A click that brings the window forward does not follow a link in the reader. See the gotchas under PR E.

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

**Not checked in Phase 0, checked 2026-11-10** on a signed Debug build (`DESTINATION='platform=macOS' ./Scripts/codex-build.sh`, Xcode 27.2):

- **The signature and its real entitlements.** `codesign --verify --deep --strict` passes, and so does `Scripts/verify-mac-test-host.sh`.
  - The signature has the hardened runtime and these entitlements: `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.personal-information.addressbook`, `com.apple.security.files.user-selected.read-write`, and `keychain-access-groups` with the team-prefixed `com.esc.inboxchat`.
  - As a Debug build it also has `com.apple.security.get-task-allow`. It has none of the testing exceptions that a test host carries (PR F).
  - The embedded profile is "Mac Team Provisioning Profile: com.esc.inboxchat".
  - The Mac it was built on had no signing certificate and no Mac profile. With Kevin's permission, the first build passed `-allowProvisioningUpdates`, and Xcode created both in the developer account. That build also wrote `esc-chatmail.xcodeproj/xcshareddata/xcodecloud/manifest.json`, which was untracked until it was committed on 2026-11-11.
- **The processed Mac `Info.plist`.**
  - No build variable is left unresolved, and none of the iOS-only keys is present.
  - The one registered URL scheme is the reversed `GOOGLE_CLIENT_ID`, and it is the scheme of `GOOGLE_REDIRECT_URI`.
  - `LSMinimumSystemVersion` is 26.0, and `CFBundleDisplayName` is MushMail.
  - There was no icon key on that day. The icon came on 2026-11-11 (see "Name and icon" in Phase 2).

At the end of Phase 0 the Mac build was red. It stayed red until Phase 1 landed, and nobody launched it before PR C.

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

**Merged 2026-11-09:**

| Piece | PR |
|---|---|
| PR A | 365 |
| PR C | 366 |
| WebKit spike | 367 |
| PR B | 368 |
| PR E | 369 |
| PR D | 370 |
| Follow-ups to B, D and E | 371 |
| PR F | 374 |
| Follow-ups to F | 376 |

After PR 371 the Mac app compiled with 0 errors. PRs B, D and E were compile-checked and unit-tested only: none of their Mac behavior had run in a launched app when they merged.

**WebKit spike (1–2 days, throwaway branch).**

- Render a chat that has an HTML preview card on macOS, scroll past the card with a trackpad, and open the full reader.
- Compare a `WKWebView` wrapped in `NSViewRepresentable` with SwiftUI's `WebView`/`WebPage` (macOS 26 and later).
- The result decides how PR E is built.
- **Done 2026-11-09:** use `WKWebView` in `NSViewRepresentable`. The results are under PR E.

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
    - **Found 2026-11-10: that is wrong inside a sheet.** A Mac sheet has no toolbar and draws no item placed at `.navigation` or `.primaryAction`, so Participants, Forward and New Message had no Done, Cancel or Send. A sheet also needs a size: the app's sheets ask for none and came up as an empty strip 80 points tall that still blocked the window and Quit. Sheets now use `sheetLeadingBarEdge` and `sheetTrailingBarEdge` (`.cancellationAction` and `.confirmationAction` on the Mac) and `macSheetSize(_:)`; the reader gets a Done bar. Measured with a throwaway Mac program on macOS 27.2, not yet seen in the app.
    - **Changed 2026-11-10, in the follow-up to PR 378.** Measured the same way, and not yet seen in the app either:
      - **One presenter.** Every sheet is presented with `appSheet(…mac:…)`, which takes its Mac size and Done-bar choice (`MacSheetChrome`) as a required argument; `macSheetSize(_:)` and `macSheetDoneBar(_:)` are gone, and `AppSheetSourceTests` fails on a raw `.sheet(` in code the Mac compiles.
      - **Titles.** A Mac sheet draws a `navigationTitle` (Participants had its title all along) and no `.principal` item, so Forward had none. Forward now gets one on the Mac (`macSheetNavigationTitle(_:)`). An empty navigation title draws an empty strip, so New Message, which draws its own title, gets none.
      - **Done.** Return and Escape now both close the Participants sheet and the reader. With no button and no focused text field, Escape does not close a Mac sheet at all.
      - **Escape in compose.** With a text field focused, Escape closed New Message and Forward by itself, pressing no button, and the draft was discarded. Both now disable interactive dismissal on the Mac, so Escape presses Cancel (or New Message's close button), which asks before discarding the user's edits (`ComposeCancelPolicy`). iOS is unchanged.
      - **Width: fixed 2026-11-10, in the follow-up to PR 379.** In the same program a sheet opened at its ideal height but not its ideal width: 470 points wide, or the minimum width `MacSheetSize` then had where that was more (Participants 470 by 545, Forward 480 by 625, New Message 480 by 560, the reader 560 by 720, not 760 wide).
        - **Cause.** The Mac's own sheet sizing (`PresentationSizing.automatic`) offers the content 470 points of width and leaves the height to it. A frame answers an offer with the nearest width it allows, so one with a minimum and an ideal width answers 470, or its minimum.
        - **Fix.** A `MacSheetSize` has one width, and `MacSheetChromeModifier`'s frame allows no other: its minimum, ideal and maximum width are all that width. Each sheet now opens at its size: Participants 420 by 545, Forward 600 by 625, New Message 600 by 560, the reader 760 by 720. The 65 points over the ideal height on the first two are the row of buttons the Mac draws for a sheet's toolbar. Both bounds are needed: without the maximum Participants opened 470 wide, and without the minimum the reader did.
        - **Nothing else changed.** No sheet can be resized, as before. A short window still caps the height 40 points under the window's content, down to the minimum and no further: on a window 500 points tall Participants opens 420 by 460 and the reader 760 by 480. A narrow window does not cap the width, and did not before: the reader opens 760 wide on a window 300 or 500 points wide (it was 560 wide on both). The Contacts sheet, which sizes itself, is 470 by 175 and pixel for pixel what a bare `sheet` draws, alone and after Participants.
        - **Tried first and dropped: fitting the sheet's sizing to its content** (`presentationSizing(.automatic.fitted(horizontal: true, vertical: false))`). It gave the same widths, with three faults, each measured. `AppSheetSourceTests` now fails on a `presentationSizing` call in code the Mac compiles.
          - The content was laid out twice as the sheet opened: the reader 560 wide, then 760. A reader whose email is ready makes its WebView in the first layout, and a pre-rendered WebView is adopted only at the width it was rendered at, so no open could adopt one.
          - Each sized sheet's window could be resized. The reader asks for a new pre-render at every whole point of width it is laid out at, and stepping its sheet 200 points wider laid it out at 200 widths.
          - `appSheet(item:)` reuses the sheet's window when one item follows another, and a fitted window kept what it had. The app's one such case is Participants and then the Contacts sheet, which could then be resized. The reader swapped in for Participants opened at Participants' size (420 by 545), and Participants swapped in for the Contacts sheet at that sheet's size.
        - Not seen in the app. The `MacSheetSize` presets are still first guesses, and the reader's width as a sheet stays in "First launch"'s list of things not checked. Return and Escape were not measured again: the frame's width does not touch them.
  - `navigationBarTitleDisplayMode` and `textInputAutocapitalization` stay iOS-only.

**PR E: WebKit (about 90 errors).** Build it on `WKWebView` wrapped in `NSViewRepresentable`, as the WebKit spike found (results below).

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
- **What to test:**
  - AGENTS.md warns that changes to snapshot sizing and to `MiniEmailWebView`'s fallback height can destabilize chat scrolling.
  - The transcript's check for when to reveal the newest message (`ChatTranscriptRealizationPolicy`) was tuned on iOS.
  - So test long chats and window resizing on the Mac.

**Mac equivalents.** These WebKit APIs worked on the Mac as they do on iOS, so the code that calls them carries over: `WKNavigationDelegate` and its policy decisions, a `WKURLSchemeHandler` such as `CIDSchemeHandler`, `loadHTMLString`, `evaluateJavaScript` and `takeSnapshot`. The iOS-only API maps like this. The spike checked every row except the last three, which come from reading the code:

| iOS | Mac |
|---|---|
| `UIViewRepresentable` | `NSViewRepresentable` |
| `layoutSubviews` and `didMoveToWindow` overrides | `setFrameSize(_:)` and `viewDidMoveToWindow()`. `layout()` also fires, but only for about a quarter of SwiftUI's frame changes |
| `isUserInteractionEnabled = false` | Override `hitTest(_:)` to return nil |
| `scrollView.isScrollEnabled = false`, `bounces = false` | Nothing more: when `hitTest` returns nil, no wheel event reaches the web view |
| `scrollView.setContentOffset(.zero)` at pool checkin | `evaluateJavaScript("window.scrollTo(0, 0)")`. It works with page JavaScript turned off |
| `scrollView.contentInsetAdjustmentBehavior = .never` | Nothing in the Phase 1 window. Use `obscuredContentInsets` (macOS 26) if the reader later sits under a transparent toolbar |
| `overrideUserInterfaceStyle` set to `.light`, `.dark` or `.unspecified` | `appearance` set to `NSAppearance(named: .aqua)`, `NSAppearance(named: .darkAqua)` or nil. CSS `prefers-color-scheme` follows, even for a web view in no window. A SwiftUI `colorScheme` environment value also reaches a hosted web view |
| `isOpaque = false`, `backgroundColor`, `scrollView.backgroundColor` | `underPageBackgroundColor`, plus `setValue(false, forKey: "drawsBackground")` for a see-through page. That key is private API, so check `responds(to: NSSelectorFromString("_setDrawsBackground:"))` first. `underPageBackgroundColor = .clear` alone leaves the page white |
| `dataDetectorTypes` | Not available. The `x-apple-data-detectors` branch of the navigation policy never runs on the Mac |
| `allowsInlineMediaPlayback` | Not available; the Mac always plays inline. `mediaTypesRequiringUserActionForPlayback` and `allowsAirPlayForMediaPlayback` exist on both |
| `takeSnapshot` returns a `UIImage`, and `image.scale` gives its pixel scale | It returns an `NSImage` sized in points. The pixel scale is the CGImage's width divided by `size.width`: 2 on a Retina screen, even with no window |
| `jpegData(compressionQuality: 0.82)` | `NSBitmapImageRep(cgImage:).representation(using: .jpeg, properties: [.compressionFactor: 0.82])` |
| `layoutIfNeeded()` | `layoutSubtreeIfNeeded()` |
| An offscreen `UIWindow` past the left edge of the screen | A borderless `NSWindow` at (-30000, -30000) with `ignoresMouseEvents`. It doesn't need to be ordered in |
| Visible-row warm width from the screen's width (`currentVisibleRowWarmWidthEstimate`) | The reader's own width. A Mac screen is far wider than the reader, so a web view warmed at screen width never matches a checkout. Warming after an explicit open already uses the reader's width |
| `UIApplication.didReceiveMemoryWarningNotification` | PR B's memory-pressure source |
| `UIApplication.shared.open(url)` | `NSWorkspace.shared.open(url)` |

**WebKit spike results (2026-11-09).**

- **Setup.** A throwaway Mac app, outside the repo, built for macOS 26 and run on macOS 27.2 with a Retina display. Like the Phase 0 settings, it was sandboxed and allowed only outgoing connections.
  - It rebuilt three things, once with each approach: the chat transcript (an 80-row `LazyVStack` with inline HTML cards), the snapshot renderer, and the full reader with its warm pool.
  - Trackpad gestures, mouse-wheel clicks and mouse clicks were synthesized inside the app.
  - Three app files compiled into it unchanged: `HTMLPreviewRenderingSupport.swift`, `HTMLPreviewScaleCalculator.swift` and `EmailWebViewLoadCoordination.swift`.
- **Why `WKWebView` rather than SwiftUI's `WebView`/`WebPage`:**
  - The app still supports iOS 17.6, and `WebPage` needs iOS 26. It would mean a second, Mac-only copy of the preview and reader views, the warm pool, `CIDSchemeHandler` (rewritten as an async `URLSchemeHandler`) and the navigation delegates (rewritten as `NavigationDeciding`). With `WKWebView`, both platforms share all of them.
  - Everything the spike tried worked with `WKWebView`, using the substitutes in the table.
  - `WebPage` has three blockers, listed under the gotchas below. Its one advantage the app could use is public API for a see-through page (`.webViewContentBackground(.hidden)`).

**Scrolling over an inline card.** How far the transcript moved, in points, for each kind of card:

| Card | 150 pt trackpad gesture over a text bubble | 150 pt trackpad gesture over the card | 3 mouse-wheel clicks over the card | 400 pt gesture that starts over text, with a card sliding under the pointer |
|---|---|---|---|---|
| `WKWebView` with no override | 120 | 0 | 0 | 20 |
| `WKWebView` whose `hitTest` returns nil | 150 | 150 | 90 | 400 |
| `WKWebView` that forwards `scrollWheel` to `nextResponder` | 150 | 150 | 90 | 400 |
| `WebView(page)` | 120 | 0 | 0 | 20 |
| `WebView(page).allowsHitTesting(false)` | 150 | 150 | 90 | 400 |
| `WebView(page).scrollDisabled(true)` | 120 | 0 | 0 | 20 |
| Snapshot image (the normal chat path) | 150 | 150 | 90 | 400 |

Use the `hitTest` override for every non-interactive web view. Like `isUserInteractionEnabled = false`, it also blocks clicks, text selection and context menus.

- **Other results:**
  - **Measured height.** `evaluateJavaScript` works with `allowsContentJavaScript = false` and the wrapper's `script-src 'none'` policy. The first card had its height 0.4 s after the window appeared.
  - **Long chat.** Cards that left the `LazyVStack` and came back were rebuilt at their cached height, so nothing jumped. Each live card had its own WebContent process: 4 cards, 4 processes. That cost is one more reason to keep snapshots as the normal path.
  - **Window resizing.** Narrowing the window until a card couldn't fit its email at half scale changed the scale from 0.5 to 0.489, and the card reloaded and was measured again. Widening it changed nothing.
  - **Snapshot.** A `WKWebView` in no window rendered as it does on iOS:
    - a 360×320 pt image at 720×640 px
    - `cid:` and remote images loaded inside the sandbox
    - light or dark from `appearance`

    A render took about 1.1 s, nearly all of it the existing 250 ms and 750 ms waits.
  - **Reader.**
    - It could be forced light inside a dark window, forced dark, or left to follow the window.
    - It scrolled itself with the trackpad and the mouse wheel.
    - Paint confirmation through `takeSnapshot(with: nil)` returned 55–165 ms after the load started.
  - **Warm pool.** Warming in the offscreen window took 50–160 ms. Adoption moved the same `WKWebView` into the reader with no new navigation and at the right width. Checkin moved it back and reset its scroll position.
- **Gotchas:**
  - **Without the `hitTest` override, a card swallows scrolling.** In the spike, a transcript scroll also stopped when such a card slid under the pointer.
  - **Transparency needs private API.** Only `drawsBackground = false` makes the page see-through.
    - The wrapper paints a theme color behind every preview and the full reader, so only compose's `.simplePreview` with no theme depends on transparency.
    - Either use the guarded call or give that preview a theme color on the Mac.
  - **The offscreen pool window counts as hidden.** To macOS, a window that is off every screen isn't visible, so WebKit reports the warm page as `hidden`. On iOS, `OffscreenWebViewHost` relies on its offscreen window to keep the page painting.
    - `finalizeWarm`'s snapshot still returns, and the page turns `visible` once adopted.
    - The spike couldn't see whether the first frame after adoption flashes. If it does, `FullEmailWebViewAdoptionPolicy` can turn adoption off on the Mac.
  - **In an inactive window, the first click only activates the window.** A click on a link reached the page as `.linkActivated` only after the web view returned true from `acceptsFirstMouse(for:)`. **Decided 2026-11-11 (decision 8):** the reader keeps the default, and `LayoutAwareWKWebView` does not override `acceptsFirstMouse(for:)`.
  - **`WebPage` blockers:**
    - A `WebPage` with no `WebView` lays out 1024 px wide and ignores dark mode, and nothing can resize it. So snapshots and warm pages have to be hosted in a sized `WebView` anyway. Its `exported(as: .image(...))` returns PNG data whose `NSImage` reports pixels as points.
    - On macOS, `ScrollInputKind` has no members, so `webViewScrollInputBehavior` can't turn off wheel scrolling. `.scrollDisabled(true)` doesn't either. Only `.allowsHitTesting(false)` works.
    - When a `WebView(page)` changes identity, for example when an `if`/`else` branch flips, SwiftUI builds the new `WebView` before removing the old one. `_WebKit_SwiftUI` then traps (`EXC_BREAKPOINT` in `makeViewProvider`, with no message). Removing the old view first works.
- **Not verified:**
  - A physical trackpad. All events were synthesized.
  - What the screen shows. There was no screen-capture permission, so transparency was read from snapshot pixels.
  - macOS 26 itself.
  - The app's own views, including `ChatTranscriptRealizationPolicy`.

**PR F: tooling, CI and Mac tests.**

- **Local commands.** `DESTINATION='platform=macOS' ./Scripts/codex-build.sh` and `./Scripts/codex-test.sh` work as soon as the target supports macOS, because both scripts pass an explicit `DESTINATION` through. Document this in CLAUDE.md.
- **CI.** Add a "Build (macOS)" job to `ci.yml` that builds unsigned (`CODE_SIGNING_ALLOWED=NO`) and runs no tests. A comment in `ci.yml` notes that macOS runner minutes bill at 10x.
- **Mac tests.** Add macOS to the test target in Xcode.
  - 32 of the 317 test files use UIKit or BGTask types and need `#if os(iOS)`.
  - A small `Mac.xctestplan` runs PR C's tests, the lifecycle policy, the shims, and the boundary and cursor suites (`AuthSessionTests`, `HTMLContentAccountBoundaryTests`, `IncrementalSyncCursorTests`). It shows that `Services/` behaves the same on macOS. The full suite stays on iOS.
- **Three constraints on Mac tests:**
  - **Contacts.** Nothing can grant Contacts access to a Mac test host ahead of time, the way `prepare-simulator.sh` does on iOS. The Mac plan must keep away from the real Contacts store by injecting `accessRequester`, as CLAUDE.md already asks.
  - **Signing.** On macOS, the `keychain-access-groups` entitlement must be backed by a provisioning profile, so running Mac tests in CI means setting up signing there. Until then, run the Mac test plan locally.
  - **An unlocked screen.** With the Mac's screen locked, the data-protection keychain refuses a `whenUnlocked` item with `errSecInteractionNotAllowed` (-25308), and `KeychainServiceTests.testSave_updatesAccessibilityForDuplicateItem` fails. Seen on 2026-11-09: the same build passed with the screen unlocked.
- **Done 2026-11-09:**
  - **Test target.** It gained macOS, with Kevin's permission to edit `project.pbxproj`. The same `-showBuildSettings` diff as Phase 0 showed the app target unchanged. On the test target, only `SUPPORTED_PLATFORMS`, `MACOSX_DEPLOYMENT_TARGET` and `SUPPORTS_MACCATALYST` changed; the last went from YES to NO, as on the app target.
  - **Test files.** 31 of the 336 test files are wrapped whole in `#if os(iOS)`. 12 more got narrow guards or a macOS branch: `AuthSessionTests` now uses `PresentationAnchor`, and the `Platform/` shim tests and the hosted-view helper have Mac versions.
  - **Mac test plan.** `Mac.xctestplan` has 16 suites and 211 tests, and all passed in a team-signed, sandboxed test host.
    - Signing used a Mac Team Provisioning Profile for `com.esc.inboxchat`, which `-allowProvisioningUpdates` created that day.
    - `run-tests.sh` refuses to run the tests unless `codesign` finds `com.apple.security.app-sandbox` in the host's signature.
    - The run confirmed that `APP_SANDBOX_CONTAINER_ID` is set in a sandboxed launch of this app (PR C's tripwire signal), and that the data-protection keychain works with the access group.
  - **Test-host entitlements.** A build for testing also carries Xcode's testing exceptions: read-only access to `/`, which lets the source-reading tests work, and mach lookups for `testmanagerd`. Writes stay confined to the container.
  - **Test-host store.** The container is the Mac app's real one, and the host loads `CoreDataStack.shared` at launch. At the default URL that opened the app's mailbox with the checkout's model: a newer model would migrate it, after which the installed app's recovery ladder would delete it, and an older model would make the host's own ladder delete it. In a Mac test host the shared stack now loads a throwaway store under the temporary directory (`MacUnitTestHostStoreTests`). The container's files, `UserDefaults.standard` and keychain are still the real ones.
  - **Follow-up, same day (the open findings of PR F's review).**
    - **Host guard.** A Mac unit-test host now checks itself, first thing in `esc_chatmailApp.init` (`MacUnitTestHostGuard`, deciding with `MacUnitTestHostPolicy`). It exits unless it is sandboxed and was started by `Mac.xctestplan`, which marks its host with `ESC_CHATMAIL_MAC_TEST_PLAN`. Before, Cmd-U in Xcode on My Mac, or a plain `xcodebuild test`, ran the full iOS plan in a Mac host, and those suites are not written to stay out of the app's real container. Checked live: with the marker taken out of the plan, the sandboxed host logged the refusal and exited with no test started.
    - **`run-tests.sh`.** `DESTINATION` must name its platform, `-destination` and `-testPlan` arguments are refused, and the host lookup now gets `-configuration`, `-xcconfig` and the other options that decide where products go. Without them it could check one host and launch another.
    - **Sync defaults.** The incremental sync path keeps its `UserDefaults` state in an injected store (`.standard` in production). `IncrementalSyncCursorTests` passes its own suite, so it no longer sets `installTimestamp`, `lastSuccessfulSyncTime` and `lastReconciliationTime` in the standard defaults, which in a Mac test host are the real app's.
    - **CI.** The Mac job compiles the test target as well as the app (`codex-build.sh --for-testing`), unsigned, and runs nothing.
    - **Mac test plan.** `Mac.xctestplan` is now 17 suites and 220 tests.
  - **Not covered.** CI runs no Mac tests.

**Phase 1 is done when** all of the following work on the Mac: sign in, initial sync, open a chat, send a reply, archive, sign out and sign back in. The iOS suite stays green, and the Mac CI build is green.

**First launch (2026-11-10).** This was the first time the Mac app ran as an app instead of as a test host. It was the signed Debug build described under Phase 0, checked with `Scripts/verify-mac-test-host.sh` right before it was opened. Kevin used the app. These results come from the process and the system log; nobody recorded what the screen showed.

- **Sandbox.**
  - The launch created `~/Library/Containers/com.esc.inboxchat`, and the Core Data store opened inside it.
  - The fresh-install cleanup ran there and finished, with no tripwire refusal.
  - That Mac has a real `~/Documents/Messages` folder that has nothing to do with the app. The launch left it alone. It is the folder an unsandboxed cleanup would have deleted.
- **Sign in.** It worked: 30 s after launch the app created the account and fetched its 4 aliases and 15 labels.
- **Initial sync.** 5 messages in 4 conversations, with 0 failures, in 0.9 s.
  - Initial sync starts at the install time, as on iOS. A new Mac install therefore begins with only the mail from about five minutes before first launch.
  - **Decided 2026-11-11 (decision 6):** it stays that way. The open question was whether a desktop app that replaces the web app should load older mail.
- **Open a chat.** The log shows a mark-read queued for one message, which is what opening a chat does. The incremental sync after it ran clean, and reconciliation found no drift.
- **Errors.** The app's own log had none, and there was no crash report.
- **Sheets: see the note under PR D.** "Found 2026-11-10: that is wrong inside a sheet" records a failure this section does not: a chat's Participants sheet came up as a strip 80 points tall with no Done button, and blocked the window and Quit until the app was force-quit. PR 378 read that from the system log, not from the screen, and the app's own log would not show it. It is not established that it happened at this launch.
- **Seen in the system log and not traced:**
  - Contacts logged the fault "Attempt to read notes by an unentitled app" once, at sign-in. Some fetch asks for a contact key the app has no entitlement for.
  - The sandbox repeatedly denied `system-info net.link.addr`, a read of a network interface's address.
  - WebKit's helper processes logged their startup errors.
- **Not walked yet, from the Phase 1 check:** send a reply, archive, sign out and sign back in. The Mac had no way to sign out until PR 378 added the Sign Out… command (see "Settings" in Phase 2).
- **Not checked yet, from the PRs:**
  - PR C: quit and relaunch, to confirm the session survives.
  - PR B: sync across sleep and wake, the maintenance jobs, and quitting during a send.
  - PR D: Quick Look, the file importer, the Contacts hand-off and the sign-out alert.
  - PR E: the reader's first frame after adoption, scrolling over preview cards with a trackpad and a mouse wheel, window resizing, and the reader's width as a sheet.

## Phase 2: make it a Mac app

- **Windows.** Show the main UI in a single window. Use either a `Window` scene, or a `WindowGroup` where `CommandGroup(replacing: .newItem)` turns File → New Window into New Message (Cmd-N).
  - **Built 2026-11-10** as a `Window` scene, with Cmd-N as New Message (`docs/mac-imessage-ui-plan.md`, PR 1). Compiled and unit-tested; not yet seen in the app.
  - Why one window: `ChatReplyComposerDirectory` lets only the most recently shown composer write a conversation's draft, so two windows on the same chat would fight over its draft.
  - Revisit multiple windows after reviewing that rule.
- **Layout.** On the Mac, use a `NavigationSplitView`: the conversation list (search and filters) in the sidebar, the chat in the detail column. Branch at the root view.
  - **Built 2026-11-10** (`MailboxRootView`, `MacMailboxView`). The detailed plan, and the restyle to match Messages that follows it, are in `docs/mac-imessage-ui-plan.md`.
  - **Used with real mail 2026-11-12 (build 528):** the sidebar drew the wrong rows after the first sync, because its rows were identified by `NSManagedObjectID`. Fixed with `MacSidebarRowID` (`docs/mac-imessage-ui-plan.md`, "Found in the app"), and a Debug build with the fix was used on the real mailbox the same day with every row right. Not yet seen in a TestFlight build.
  - Keep the iPhone's `NavigationStack` as it is. The transcript's anchoring and reveal logic was tuned inside it.
- **Settings.** A `Settings` scene replaces `Settings.bundle`, which has three rows: account email, a Sign Out toggle, and the version.
  - Sign Out calls the existing `AuthSession.signOut`. Don't add a seventh AuthSession path.
  - **Added 2026-11-10, ahead of this phase:** a Sign Out… command in the app menu (`SignOutCommands`). Phase 1's check asks for a sign-out, and nothing on the Mac could raise one. The command asks through the controller that judges the iOS Settings switch, and ends in the same confirmation and the same `AuthSession.signOut`, so it adds no AuthSession path. The Settings scene can keep it or replace it.
    - **Changed 2026-11-10, in the follow-up to PR 378:**
      - The command no longer stores a request. As first written it turned on the iOS switch's key, so a force quit before the alert was answered asked again at the next launch, and a second window asked about the first window's request.
      - It asks nothing, and beeps, while the window has a sheet attached. The confirmation is an alert on that window and would wait unseen behind the sheet.
      - It is enabled for an account still held behind `SignInView` after a launch restore that failed retryably, which iOS could already sign out.
      - Its failure alert names the command. It named a Settings switch the Mac does not have.
    - Not yet seen on screen: the command, its alerts, or its state under a sheet.
  - **Built 2026-11-13** (`MacSettingsView`, the app menu's Settings…, Command-Comma). The window has the Account row, a Sign Out… button with a line under it, and the Version row (`MacSettingsPolicy`). The app menu's Sign Out… command is kept.
    - **Sign Out… in the window is the menu command as a button.** It asks through `SettingsAppSignOutController.requestSignOut` and ends in the same confirmation and the same `AuthSession.signOut`. No AuthSession path was added.
    - **The window has its own controller**, as each window does. The confirmation is then an alert on the Settings window, where the user asked (measured: an alert raised from the Settings view is a sheet on the Settings window). And the window publishes the menu command too: while Settings has the keyboard the mailbox window's focused values are not the menu's, so without that the app menu's Sign Out… would be disabled whenever Settings is in front.
    - **A sign-out started in Settings shows its progress in Settings.** The mailbox window draws its overlay only for a sign-out its own controller started, so the mailbox stays on screen, without the overlay, until teardown replaces it with the sign-in view. Nothing sent or changed there in that time gets through: `signOut()` closes admission before its first suspension.
    - **Nothing to act on before the app has initialized.** The window shows a spinner until `initializeApp()` has finished, as the mailbox window shows its loading view: a sign-out asked for earlier would start an auth transition ahead of the fresh-install check and the launch restore.
    - **Sign Out… moved in the app menu.** With the scene added, `CommandGroup(after: .appSettings)` put Sign Out… above the Settings… item (read from the test host's real menu bar). It is now in a group of its own before Services, which puts it under Settings… and its separator (`MacSettingsMenuTests`).
    - **Closing the mailbox window with Settings open** needed a fix: see "Closing the window" below.
    - **Not seen: check in the app.** Nobody has opened the window.
      - Settings… and Command-Comma open it. It shows the signed-in address and the version, and is as tall as its content.
      - Sign Out… in the window asks on the Settings window. Cancel leaves everything as it was. Sign Out shows "Signing Out…" in the window, the mailbox window changes to the sign-in view, and the Account row reads Not Signed In with the button disabled.
      - With Settings in front, the app menu's Sign Out… is enabled and asks on the Settings window.
      - With the mailbox window in front and Settings open behind it, the app menu's Sign Out… asks on the mailbox window, as before.
      - Close the mailbox window with Settings open: the app quits.
      - Close Settings alone: the app keeps running.
      - The app menu reads About, Settings…, Sign Out…, Services, each group under a separator.
    - **Left out.** A shared "signing out" overlay on the mailbox window for a sign-out started in Settings. Anything else in the window: there are no other settings.
- **Menus and shortcuts:**
  - Cmd-N new message, Cmd-R sync now, Cmd-F search. **Built** (`MailboxCommands`; Cmd-R is Mailbox > Get New Mail).
  - Delete archives (**built**, `MacConversationSidebar`).
  - Cmd-Shift-U toggles unread. **Built 2026-11-13** as Mailbox > Mark as Read / Mark as Unread (`MailboxCommands`).
    - **What it acts on** (`MacSidebarSelectionPolicy.readStateTargets`). One selected conversation: that one, even while a search hides its row, because it is the open chat. Several: the selected rows the list is showing, as for Delete. Nothing selected: the item is disabled and reads Mark as Unread.
    - **Which way** (`MailboxMenuPolicy.readStateCommand`). If any of them is unread, Mark as Read, which changes only the unread ones; otherwise Mark as Unread. Mail's rule for several messages; for one conversation it is the toggle the row's right-click menu and swipe already make, through the same calls.
    - **Decided when chosen.** The title is drawn at the sidebar's last update. The action reads the counts again (`ConversationListViewModel.changeReadState`), so a sync between the two cannot make it do the opposite of what the conversation now needs.
    - **Not under a sheet rule.** It presents nothing, so it is not refused while a sheet is attached, like Get New Mail and Search.
    - **Measured in the sandboxed test host** (macOS 27.2): the app's menu bar there is the real one, and its Mailbox menu has the item after a separator with Command-Shift-U, which no other item in the menu bar has (`MailboxCommandsMenuTests`).
    - **Not seen: check in the app.** The command has not been chosen anywhere.
      - With a chat open, Cmd-Shift-U marks it unread: the row gets its dot and the menu item changes to Mark as Read. The chat stays open. It is expected to stay unread until its row is selected again, as after the right-click menu's Mark as Unread: read from the code, a chat marks its conversation read when it appears and marks mail that arrives while it is open, and nothing else.
      - Pressed again, it marks the chat read.
      - With the caret in the reply field or the search field, the shortcut is expected to work and type nothing.
      - With several rows selected, one of them unread: all become read. Pressed again: all become unread.
      - With a search hiding the open chat's row, the item's title can be a step behind, because the sidebar updates on changes to the rows it shows. The action is still right.
    - **Left out.** Mark as Read / Mark as Unread in the right-click menu of several selected rows, which still offers only Archive and Report Spam.
  - Space opens Quick Look on an attachment; Escape leaves selection. **Not built.** A click on an attachment opens Quick Look. Space needs an attachment to be selected first, and nothing in the transcript can be selected.
  - Return sends; Option-Return or Shift-Return adds a new line. **Built** in the reply field (`ReplyFieldKeyPolicy`; `docs/mac-imessage-ui-plan.md`, PR 5).
- **Toolbar.** New message, sync and search go in the window toolbar.
  - **Built:** New Message, at the chat column's leading edge. Search is the sidebar's own field, as in Messages.
  - **Not built:** a sync button. Sync is the Cmd-R menu command only; Messages' toolbar has nothing like it.
- **Selection.** **Built** (`docs/mac-imessage-ui-plan.md`, PR 1).
  - `List(selection:)` with Shift-click and Cmd-click drives the existing selection service and batch actions.
  - Rows and message bubbles get right-click menus.
- **Files.**
  - Drop files into the composer, through the existing draft-attachment import. **Built 2026-11-12 for the chat's reply** (below). Not for New Message or Forward, whose sheet has its own attachment code (`ComposeInputBar`).
  - Drag attachments out of a message. **Built 2026-11-13** (below), as a file promise.
  - Add Save Attachment…. **Built 2026-11-13** (below), with AppKit's save panel, not `fileExporter`.
  - Open attachments in their default app (`NSWorkspace`). **Not built.** It needs a rule for which kinds of file may be opened: `NSWorkspace.open` on an attachment runs whatever the file's type launches.

  **Files dropped on a chat, as built (2026-11-12).** A file dragged from the Finder onto the chat column, anywhere on it, becomes an attachment of the reply.

  - **What it takes.** What the "+" menu's Files picker offers, images and PDFs, through the same import (`DocumentAttachmentImporter`): the same size budget, the same re-encoding of images, the same placeholder and thumbnail. A dropped file of another kind, or a folder, is named in the alert that import failures use ("… can’t be attached. Only images and PDFs can be."). A drop is refused, and the pointer shows no copy badge, where the picker's button is disabled: while a send owns the draft and while another import is running (`DraftFileDropPolicy`). It is also refused while the window has a sheet attached.
  - **How.** `ChatView` puts one AppKit view behind the whole chat (`View.macDraftFileDrop`, `MacDraftFileDropView`), registered for file URLs and returning nil from `hitTest`, so it takes drags and no clicks. A drop becomes `ChatComposerState.pendingFileDrop`, which the composer's `AttachmentPicker` imports once and clears as it starts. Until then the composer takes no other drop, and a picker that hears of the drop while an import is running keeps it and starts when that import ends (`DraftFileDropPolicy.startsImport`; added 2026-11-13, after the review of PR 404: the picker used to clear such a drop and import nothing, with the files already gone from the pointer). What a drag carries is asked of the pasteboard once for each drag, kept under its sequence number. The chat does not observe the composer's state for this: the drop view's closures read it when a drag asks.
  - **Why not SwiftUI's `dropDestination`.** Measured in the sandboxed test host on macOS 27.2, by giving the window's own private drag hit test (`-[NSWindow _findDragTargetFrom:]`) a stand-in drag at points over a chat-shaped view:
    - A SwiftUI drop destination is an AppKit view placed behind the content. Over SwiftUI-drawn content, and over an AppKit view not registered for drags, AppKit chose it.
    - Over the reply field it chose the field's text view, which **typed the file's path into the draft**.
    - Over a web view it chose the web view, with `hitTest` returning nil (`makeNonInteractive()`) and after `unregisterDraggedTypes()` alike. Given the drop, the web view **loaded the dropped file in place of its page**, as a navigation of type `.other` (its delegate in that measurement allowed everything). A preview card's delegate allows `.other`, the type of its own first load, so a file dropped on an email card in the transcript is expected to have replaced the card's content, on any Mac build before this change. That was read from the card's delegate, not run with it.
    - A drop view of the app's own can be handed a drag by another view, which a private SwiftUI view cannot. So the text view and the web view hand a file drag to the drop view under the pointer (`MacFileDropForwarder`), and it can refuse a drag before the drop where a SwiftUI destination can only refuse the drop.
  - **The reply field** (`MacReplyTextView`). A drag of files goes to the chat; with no chat behind the field it is refused, so a path is never typed. A drag of text is the text view's, as before.
  - **Every email web view** (`LayoutAwareWKWebView`: preview cards and the reader). No drag reaches WebKit any more. A drag of files goes to the chat behind the web view; every other drag, and a file drag over the reader's sheet, is refused.
  - **Security scope.** In the sandboxed test host `startAccessingSecurityScopedResource()` answers false for a file URL that came from no picker, read from a pasteboard or not. The pickers' import requires that call to succeed; a drop's import does not (`DocumentAttachmentImporter.SecurityScope.ifOffered`) and reads the file anyway. The test host logged "No sandbox extension entry in cache when one was expected … flavor: public.file-url" for the tests' stand-in pasteboards, so a real drag's pasteboard is expected to carry the permission to read its files. That is the one link not measured: no file from outside the container was dropped.
  - **Tests.** `DraftFileDropPolicyTests` (both platforms) and `MacDraftFileDropViewTests` (the Mac plan): the real drop view, the real reply field and a real `LayoutAwareWKWebView` in a window that is never shown, each handed a stand-in drag (`FakeDraggingInfo`). `DocumentAttachmentImporterTests` gained the import of a real file, which it had no test of. `ChatFileDropSourceTests` pins the wiring from the chat to the picker. Each of the 46 changes named in their `Revert-check:` comments was undone alone, and each time a test that names it failed.
  - **Not seen: check in the signed, sandboxed app.**
    - A PDF and an image dragged from the Finder onto the transcript, onto the reply field and onto an email card: each appears in the strip above the field, and nothing is typed and no card changes.
    - A file from outside the app's container is read. If the alert says it "could not be read", the drag's permission did not reach the import.
    - The pointer's copy badge over the chat, and none while a send is in flight or over the sidebar.
    - A `.zip` dropped: the alert names it. A PDF and a `.zip` together: the PDF is attached and the alert names the `.zip`.
    - A drag over the chat while a sheet is up (New Message, the reader): whether AppKit offers it at all was not measured; it should be refused.
    - A photo dragged from Photos, an image from Safari, an attachment from Mail: these are file promises, not files, and are not taken. Whether the pointer shows a badge for them was not measured.
    - Scrolling the transcript and clicking its empty space are as before, with the drop view behind it.
  - **Left out.** Paste: a file copied in the Finder and pasted into the field still types its path (measured by having the text view read a pasteboard of a file URL), and a copied image is not attached. A highlight on the chat while a file is over it. File promises. The New Message and Forward sheet.
  **Save Attachment…, as built (2026-11-13).** A right-click on an attachment in a chat opens the attachment's own menu: Quick Look, Save Attachment…, and Save All Attachments… where the message shows more than one.

  - **Where the menu is.** On each attachment view (`View.macAttachmentExportMenu`, `MacAttachmentExportMenu`), applied by `AttachmentGridView` to a single attachment and by `AttachmentGrid` to each cell. The message's row has a menu of its own; a right-click on a view with its own context menu opens that one. Measured in the sandboxed test host on macOS 27.2, by asking the hosting view for the menu of a right-click (`NSHostingView.menu(for:)`): a `contextMenu` inside another that has a preview answered with the inner one's entries. So the row hands its own entries down to the views inside it (`View.macEnclosingMessageMenu`, an environment value), and the attachment's menu ends with them after a separator: Reply, Forward, View original email, and a failed send's entries (added 2026-11-13, after the review of PR 406: a message that was only a photo had no Reply in any menu). They are built from the definition the row's own menu uses.
  - **Why on the attachment and not in the message's menu.** Which attachments a message shows is decided in its bubble, from the HTML analysis its load produces (`AttachmentDisplayFilter`). The row's menu has only the row's snapshot and would list inline images the bubble hides.
  - **The entries** (`AttachmentExportPolicy.menu`). The same entries for every state of the attachment, with those that need its file disabled until it has one. Save All counts and saves the attachments that have their file.
  - **The name** (`AttachmentExportPolicy.filename`). The sender's, which is untrusted, with these removed: any path (only the last component is kept, `/` and `\` both read as separators), control characters, the characters that change the direction text is drawn in, and leading dots. A `:` becomes `-`. A name with no extension of its own gets its type's (`AttachmentPaths.fileExtension(for:)` of the MIME type), unless that is the one given to a file of no known type. What counts as an extension has one definition, `splitExtension`, asked by the name, by Save All's numbering, by the truncation and by a drag's file type: what follows the last dot when it is short, has no space in it and is not all digits. So `main.c++` keeps its own, and `Screen Shot at 1.02.33` gets `.png` (changed 2026-11-13, after the review of PR 408: digits read as an extension, and the extension added was the stored file's, which the download takes from the same digits). An empty one is "Attachment". The file on disk is named for its storage identity and is never the name offered. The name is cleaned one Unicode scalar at a time, never one `Character`: a `/` followed by a combining scalar is one `Character` that is not `/`, and the first version kept `Library/<zero-width joiner>x.plist` whole, so Save All wrote into a `Library` folder of the chosen folder (found in review of PR 406).
  - **Which file** (`AttachmentExportItem`). The attachment's own, through `readableLocalURLValue`. Never the preview image, which Quick Look falls back to: for a document that is a picture of its first page.
  - **The panels** (`MacAttachmentSavePanels`). `NSSavePanel` for one file, with the name in its field; `NSOpenPanel` choosing a folder for Save All. Each is a sheet on the app's window. The sandbox lets the app write where a panel returned because `ENABLE_USER_SELECTED_FILES` is `readwrite` for the Mac. Not `fileExporter`: it writes the file itself, so the copy, the name of each file of a Save All and what happens to a file already there could not be tested or chosen.
  - **The copy** (`AttachmentFileExport`), off the main thread. Save Attachment… replaces a file at the chosen place, which the panel has asked about. The old file is never removed first: the attachment is copied into the directory the system gives for replacing an item (`.itemReplacementDirectory`) and swapped in with `replaceItemAt` once the copy is whole, so a failed copy leaves the old file (the first version removed it first; found in review of PR 406). Save All replaces nothing: a name already in the folder, or used by an earlier attachment of the same save, gets a number (`image 2.jpg`). What could not be saved is listed in one alert.
  - **A sign-out while a panel is up** deletes the files. The save then says the attachment is no longer on this Mac and writes nothing. The panel is not closed for it.
  - **Tests.** `AttachmentExportPolicyTests`, `AttachmentFileExportTests` and `AttachmentExportItemTests` (both platforms, files in a temporary directory); `MacAttachmentExporterTests` (the Mac plan, stand-ins for the panels and the alert); `MacAttachmentExportMenuTests` (the Mac plan: the real modifier on a stand-in row, its menu read from the hosting view and its entries chosen with `performActionForItem`); `AttachmentExportSourceTests` pins that the two attachment views carry the menu, and `MacEnclosingMessageMenuSourceTests` that the transcript's row hands its entries down.
  - **Not seen: check in the signed, sandboxed app.**
    - A right-click on a photo, on a PDF card and on a cell of a grid opens the three entries, and a right-click beside the bubble still opens Reply and Forward.
    - Save Attachment… opens a sheet with the attachment's name in the field, and the saved file opens. Saving over an existing file asks first, and then replaces it: the replacement goes through a system directory beside the destination, which the tests ran only inside the app's own container.
    - Save All Attachments… asks for a folder and writes every file, numbering names that are taken.
    - A right-click on an attachment in a window that is not the front one: which window the sheet attaches to.
    - A click on an attachment still opens Quick Look.
    - A right-click on an attachment: its entries, a separator, then the message's, and Reply chosen there is a reply to that message.
  - **Left out.** The menu on iOS. Attachments shown inside the full email reader.

  **Dragging an attachment out, as built (2026-11-13).** An attachment that has its file can be dragged from the chat to the Finder or to another app, where it arrives under the name a save would offer.

  - **A file promise, not the file's URL** (`MacAttachmentFilePromiseProvider`). The file on disk is named for its storage identity, and the Finder copies a dragged file under the name it has. With a promise the receiving app says where the file goes and the app writes it there under `AttachmentExportPolicy.filename`. The other way to carry the name, a renamed copy in the app's container, would be a second copy of an account's attachment that sign-out would have to find and delete. The cost: an app that takes file URLs and not promises does not take the drag.
  - **An AppKit view over the attachment, not `onDrag`** (`MacAttachmentDragSourceView`, `View.macAttachmentDragSource`). An `onDrag` item provider cannot be a file promise with a name the app chooses and can test. And every attachment view is a `Button`: whether `onDrag` starts a drag at all over a button, and what it does to the click, can only be seen by dragging with the real pointer, which nothing here did.
  - **The view takes the left mouse button.** A press that moves 4 points starts the drag (`AttachmentDragPolicy`); one released in place is handed on as the attachment's click, which opens Quick Look. So the view is only over an attachment that has its file, where that click is the button's whole job: a failed attachment's retry control has no view over it. The view is put there when the row is drawn, so it also asks at every press whether the attachment still has its file (`hitTest`, `AttachmentDragPolicy.takesMouse`) and takes none where it does not: the press is then the attachment's own button's. A right-click on the view gets the menu of the views behind it (`menu(for:)`), which is the attachment's. The scroll wheel is not handled by the view.
  - **Where it may be dropped.** Outside the app only. Nothing in the app takes an attachment back, and the reply field and the email web views are offered nothing.
  - **Keeping the promise** (`AttachmentFileExport.writePromise`), off the main thread. Nothing is replaced at the place the receiving app names. If the file is gone (a sign-out during the drag) the promise is answered with the error.
  - **Measured in the sandboxed test host** (macOS 27.2): with the view mounted over a button inside the row's menus, AppKit's hit test at a point on the attachment returns the view; its `menu(for:)` answers with the attachment's entries; a press and release handed to it calls the click once. That the button under the view is then left alone was not measured (events sent through a window that is never shown reached neither): it rests on AppKit giving a press to the one view its hit test chose.
  - **Tests.** `AttachmentDragPolicyTests` (both platforms); `MacAttachmentDragSourceViewTests` and `MacAttachmentFilePromiseProviderTests` (the Mac plan); `AttachmentExportSourceTests` pins the wiring and its order.
  - **Not seen: check in the signed, sandboxed app.** No dragging session was started by any test (a session is the window server's and follows the real pointer).
    - Drag a photo, a PDF card and a grid cell to the desktop: the file arrives under the attachment's name and opens.
    - Drag one into a Mail or Messages draft, and onto an app that takes only file URLs (a browser's upload field): the second is expected to refuse it.
    - A click on a downloaded attachment still opens Quick Look, once. The button no longer shows its pressed look.
    - A right-click on a downloaded attachment still opens the attachment's menu.
    - Scrolling with the pointer over an attachment, and a click on an attachment in a window that is not the front one (expected only to bring the window forward).
    - Dragging a file to a folder that already has one of that name: the promise is not kept and nothing is replaced; what the Finder says then was not seen.
  - **Left out.** Dragging several attachments at once. A picture of the attachment as the drag's image (it is the file's icon). Dragging on iOS.
- **Closing the window quits the app. Decided 2026-11-11 (decision 7).** The alternative was to keep running and syncing like Mail, where clicking the Dock icon reopens the window. Sync follows the app's lifetime, so it stops when the window closes.
  - **How.** The mailbox is a `Window` scene (built 2026-11-10), and SwiftUI quits an app whose one `Window` closes; a `WindowGroup` app keeps running. The quit goes through `MacAppDelegate`, so a send in flight is still waited for.
  - **Since the Settings scene (2026-11-13) the app also quits itself** when the mailbox window closes (`MacMainWindowPolicy`, `MacMainWindowCloseObserver`, started by `MacAppDelegate`). SwiftUI's own quit is not enough with a second scene:
    - **Measured 2026-11-13 in a stand-in program** on macOS 27.2 (one `Window`, one `Settings` scene, a delegate that does not answer `applicationShouldTerminateAfterLastWindowClosed`, windows kept invisible):
      - Settings never opened: closing the window quit. Settings opened and closed again, then the window closed: it quit.
      - Settings open, the window closed: the program ran on with only the Settings window, and quit when that was closed.
      - With the program quitting itself when the window with the scene's id closed, it quit at once in all three cases, and `applicationShouldTerminate` was called once in each, including the ones where SwiftUI's own quit follows the same close.
      - The window's AppKit `identifier` was the scene's id, `main`. The Settings window's was `com_apple_SwiftUI_Settings_window`.
    - **The quit must be asked for from the run loop** (`perform(_:with:afterDelay:)`), never from a block on the main queue or a main-actor task. The delegate holds a quit for a send in flight and answers from a main-actor task. Asked for from a main-queue block, with the delegate answering `.terminateLater` and replying from the main queue a second and a half later, the stand-in never quit: `terminate(_:)` waits inside the block, and the queue cannot run the reply. Asked for from the run loop, it quit when the reply came, in all three cases.
    - The observer is not started in the unit-test host.
    - Not seen in the app: nothing has closed the app's window with its Settings window open, with or without a send in flight.
  - **Measured 2026-11-11 in a stand-in program** on macOS 27.2, not in the app:
    - Closing the window of a one-`Window` app called `applicationShouldTerminate` on the delegate installed with `@NSApplicationDelegateAdaptor`, and the process exited.
    - It still quit with a borderless window that is never ordered in, the shape of `OffscreenWebViewHost`'s window.
    - It still quit with a `Settings` scene declared and not open.
    - A `WindowGroup` app was still running three seconds after its window closed. It quit once its delegate returned true from `applicationShouldTerminateAfterLastWindowClosed(_:)`.
    - Not measured then: closing the main window while a Settings window is open. Measured 2026-11-13, above.
  - Keep the primary scene a single `Window`, and keep its id `MacMainWindowPolicy.windowID`, which is how the observer knows the window. If it ever becomes a `WindowGroup`, add that delegate method, or the app is left running with no window.
- **Name and icon.** Both are in place.
  - **Icon (2026-11-11).** `AppIcon` has the ten macOS slots (16, 32, 128, 256 and 512 points, at 1x and 2x) beside the iOS image, whose entries are unchanged.
    - **The files.** Seven `mac-icon-<pixels>.png` files fill the ten slots. `Scripts/make-mac-app-icon.swift` makes them from the iOS image: run it again when that image changes, and do not edit them by hand.
    - **The shape.** An iOS icon is a full square that the system masks. The Mac files draw the same image in the macOS template's shape: a rounded square 824 pixels wide on a 1024-pixel canvas, with the template's drop shadow. The script's header has the numbers.
    - **What macOS draws.** macOS 26 and later redraw every app icon in the system's own shape, with the system's shadow. Measured on macOS 27.2 with `NSWorkspace.icon(forFile:)`, which launches nothing: at 16, 32, 64, 128, 256, 512 and 1024 pixels the Mac build's icon has the outline every other app's has, with the whole image inside it. At 1024 pixels it is the installed iOS build's icon to within 23 of 255 in any channel; the smaller sizes differ more, in sharpness.
    - **Keep the scaling exact.** The system first checks each size against the template, and draws a size that does not match small, on a gray plate. A 16-pixel image scaled down with Core Graphics' high-quality interpolation got the plate. The same image scaled by block means, which is what the script does, did not. Slack's icon gets the plate at 16 and 32 pixels.
    - **Checked.**
      - iOS: the asset catalog compiles to the same bytes with and without the Mac entries (`Assets.car` and the two loose `AppIcon` files, for the simulator and for a device), and a simulator build's `Info.plist` is unchanged.
      - Mac: the unsigned compile check's product has `AppIcon.icns`, the ten sizes in `Assets.car`, and `CFBundleIconFile` and `CFBundleIconName` set to `AppIcon`. Without the Mac entries, `actool` wrote no file at all from this catalog for macOS.
    - **Not done:** small sizes drawn by hand, and a Liquid Glass icon (an Icon Composer `.icon` file). At 16 pixels "Esc" is a smudge. Both need a designer's choices, not a script.
  - **Name (2026-11-11).** The Mac product is `MushMail.app`, its executable is `MushMail`, and its menu name (`CFBundleName`) is MushMail. The iOS product is still `esc-chatmail.app`. Kevin approved the edit to `project.pbxproj`.
    - **Before,** the Mac bundle was `esc-chatmail.app`, because `PRODUCT_NAME` is the target name, and Finder showed `esc-chatmail`: `CFBundleDisplayName` was already MushMail, but `FileManager.displayName(atPath:)` returned the file's name.
    - **The change:** three settings, each scoped to `[sdk=macosx*]`, in Debug and Release. They go together.
      - App target: `PRODUCT_NAME[sdk=macosx*] = MushMail`.
      - App target: `PRODUCT_MODULE_NAME[sdk=macosx*] = esc_chatmail`. Without it the Mac module follows the product name and becomes `MushMail`, and 333 test files import `esc_chatmail`.
      - Test target: `TEST_HOST[sdk=macosx*] = $(BUILT_PRODUCTS_DIR)/MushMail.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MushMail`. The existing `TEST_HOST` line spells out `esc-chatmail.app` and its executable, so the Mac needs its own. The iOS line is as it was.
    - **Left alone:** the product's file reference in `project.pbxproj` and `BuildableName` in the scheme still say `esc-chatmail.app`. Both are labels; the builds below resolved the product from the settings.
    - **Checked.**
      - iOS: `xcodebuild test -showBuildSettings -json`, for the simulator and for a device, in Debug and Release, prints the same bytes before and after. That covers every setting of both targets.
      - Mac: the same comparison shows only names and paths changing (`MushMail.app`, the executable, the dSYM, the test host). The module name, the bundle ID and every signing setting stay.
      - The unsigned Mac compile check (`codex-build.sh --for-testing`) succeeds. Its product is `MushMail.app` with the tests inside it, Finder's name for it is MushMail, and both modules compile as `esc_chatmail` and `esc_chatmailTests`.
    - **The Mac test plan: run at the review, before the merge (2026-11-11).** It was not run when the name changed, because it launches the app as its test host and nothing launched a Mac build then. `Scripts/run-tests.sh` reads the host's path from `TEST_HOST`, so it followed the new name without a change.
      - `DESTINATION='platform=macOS' ./Scripts/codex-test.sh` on this branch with `main` merged in (PRs 384 and 385): 247 tests in 22 suites, 0 failures.
      - The host was the signed `MushMail.app`, which passed the script's sandbox check, and its process was `MushMail`.
      - Only the test host was launched. The app itself has still not been launched under the new name.
- **Optional:**
  - An unread count on the Dock icon or in a `MenuBarExtra`.
  - New-mail notifications. Neither iOS nor the web app has them today.
  - Printing.

## Phase 3: parity, then daily use

- **Close the parity gaps:** the desktop input behaviors. The From: alias picker is not built (decision 5).
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
