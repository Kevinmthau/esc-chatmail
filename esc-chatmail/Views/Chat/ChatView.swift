import SwiftUI
import CoreData
import ContactsUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var viewModel: ChatViewModel
    @State private var presentedSheetDestination: ChatDestination?
    @State private var composerHasDraft = false
    // Mirror only send ownership so typing does not invalidate the full thread.
    // It now flips only for the tap → optimistic-persistence window and feeds
    // only `shouldDismissDrainedConversation`, which is evaluated in `body`
    // and needs the reactivity; navigation no longer depends on it.
    @State private var replySendIsInFlight = false
    private let chatDependencies: ChatDependencies
    /// How this chat shows whose it is: its name as the navigation title where it is pushed
    /// (iOS), or Messages' avatar and name capsule in the Mac's chat column
    /// (`ChatHeaderPolicy`). Fixed for the chat's life.
    private let headerStyle: ChatHeaderStyle
    private let makeForwardComposeView: @MainActor (ComposeForwardModeContext) -> ComposeView
    /// How this chat leaves the screen when it closes itself; nil pops it with `dismiss`
    /// (`exitChat()`).
    private let onExit: (@MainActor () -> Void)?

    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private var windowAppearsActive = WindowAppearsActive()

    @MainActor
    init(
        conversation: Conversation,
        chatDependencies: ChatDependencies,
        headerStyle: ChatHeaderStyle,
        makeForwardComposeView: @escaping @MainActor (ComposeForwardModeContext) -> ComposeView = { context in
            ComposeView(mode: .forward(context))
        },
        onExit: (@MainActor () -> Void)? = nil
    ) {
        self.conversation = conversation
        self.chatDependencies = chatDependencies
        self.headerStyle = headerStyle
        self.makeForwardComposeView = makeForwardComposeView
        self.onExit = onExit
        self._viewModel = StateObject(
            wrappedValue: ChatViewModel(conversation: conversation, chatDependencies: chatDependencies)
        )
    }

    var body: some View {
        content
            .contactAccessPickerIfAvailable(isPresented: $viewModel.contactManager.showingContactAccessPicker) { identifiers in
                viewModel.contactManager.handleContactAccessPickerCompletion(identifiers)
            }
    }

    private var content: some View {
        ChatMessagesView(
            conversation: conversation,
            viewModel: viewModel,
            chatDependencies: chatDependencies,
            isEffectivelyOneToOneConversation: viewModel.isEffectivelyOneToOneConversation,
            isChatActiveAndUncovered: isChatActiveAndUncovered,
            isTextFieldFocused: $isTextFieldFocused,
            onOpenFullMessage: { messageObjectID, source in
                viewModel.openEmailReader(
                    for: messageObjectID,
                    source: source,
                    initialMode: .original
                )
            }
        )
        // The Mac header's name capsule, in a bar under the toolbar. On the transcript, so the
        // bar is the top of its safe area: a constant inset from the moment the chat mounts
        // (`ChatHeaderPolicy.nameBarMetrics`). Nothing on iOS, whose name is the title below.
        .macChatHeaderNameBar(
            metrics: ChatHeaderPolicy.nameBarMetrics(for: headerStyle),
            name: navigationDisplayName,
            opensParticipants: headerOpensParticipants,
            onOpenParticipants: presentParticipantsList
        )
        .navigationTitle(navigationDisplayName)
        .inlineNavigationTitle()
        .navigationBarBackButtonHidden(!allowsNavigationExit)
        .toolbar {
            ToolbarItem(placement: .principal) {
                switch ChatHeaderPolicy.principalItem(for: headerStyle) {
                case .title:
                    Text(navigationDisplayName)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard Self.allowsParticipantListPresentation(
                                conversationType: conversation.conversationType
                            ) else {
                                return
                            }
                            presentParticipantsList()
                        }
                case .avatar(let diameter):
                    ChatHeaderAvatarButton(
                        avatar: headerAvatar,
                        diameter: diameter,
                        opensParticipants: headerOpensParticipants,
                        onOpenParticipants: presentParticipantsList
                    )
                }
            }
            // The Mac header's avatar is drawn bare, as Messages' is, not on the glass the
            // Mac's toolbar puts behind an item. Nothing on iOS.
            .macSharedBackgroundHidden(ChatHeaderPolicy.hidesPrincipalItemGlass(for: headerStyle))

            ToolbarItemGroup(placement: .trailingBarEdge) {
                Menu {
                    if composerHasDraft || viewModel.draftRestoreFailed {
                        Button("Discard draft", role: .destructive) { viewModel.discardReplyDraft() }
                    }
                    Button(action: archiveConversationAndDismiss) {
                        SwiftUI.Label("Archive", systemImage: "archivebox")
                    }

                    Button(action: reportSpamAndDismiss) {
                        SwiftUI.Label("Report Spam", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(!allowsNavigationExit)
            }
        }
        // On the Mac a sheet is as large as its content asks to be, and these
        // ask for nothing, so each destination names its size (`MacSheetSize`).
        .appSheet(item: activeDestinationBinding, mac: \.macSheetChrome, onDismiss: {
            dismissActiveDestination(presentationDidEnd: true)
        }) { destination in
            destinationSheet(destination)
                .onAppear {
                    presentedSheetDestination = destination
                }
        }
        .alert(item: $viewModel.contactManager.contactActionAlert) { alert in
            switch alert.kind {
            case .contactsDenied:
                Alert(
                    title: Text("Contacts Access Needed"),
                    message: Text("Allow Contacts access in Settings to save this email to your contacts."),
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = PlatformSettingsURL.contactsAccess {
                            openURL(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .contactsRestricted:
                Alert(
                    title: Text("Contacts Access Restricted"),
                    message: Text("Contacts access is restricted on this device."),
                    dismissButton: .default(Text("OK"))
                )
            case .limitedAccessNeedsPermission(let contactName):
                Alert(
                    title: Text("Allow Access to Contact"),
                    message: Text("MushMail has limited Contacts access. To edit \(contactName), allow access to it in the next sheet."),
                    primaryButton: .default(Text("Continue")) {
                        viewModel.contactManager.presentContactAccessPickerForSelectedContact()
                    },
                    secondaryButton: .cancel()
                )
            case .error(let message):
                Alert(
                    title: Text("Couldn’t Add Email"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .alert(item: $viewModel.sendErrorAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .allowsHitTesting(!shouldDismissDrainedConversation)
        .onReceive(viewModel.composerState.hasDraftContentPublisher) { hasDraft in
            if composerHasDraft != hasDraft {
                composerHasDraft = hasDraft
            }
        }
        .onReceive(viewModel.composerState.$isSending) { isSending in
            if replySendIsInFlight != isSending {
                replySendIsInFlight = isSending
            }
        }
        .onChange(of: shouldDismissDrainedConversation, initial: true) { _, shouldDismiss in
            guard shouldDismiss else { return }
            isTextFieldFocused = false
            exitChat()
        }
        .onAppear {
            viewModel.composerDidAppear()
        }
        .onDisappear {
            viewModel.composerDidDisappear()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.scheduleReplyDraftSave() }
        }
    }

    private var navigationDisplayName: String {
        if let displayNameForNavigation = viewModel.displayNameForNavigation {
            return displayNameForNavigation
        }

        return fallbackDisplayName
    }

    /// The conversation's name from what is stored on it, before and without the participant
    /// load: the title until `displayNameForNavigation` has a name, and what the Mac header's
    /// avatar draws initials from while it has no participant to name, as the conversation's
    /// row does (`ConversationRowView.fallbackDisplayName`).
    private var fallbackDisplayName: String {
        let participantEmails = conversation.participants?
            .compactMap { participant -> String? in
                guard let person = participant.person,
                      !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) else {
                    return nil
                }
                return person.email
            }
            .filter { email in
                EmailNormalizer.normalize(email) != EmailNormalizer.normalize(
                    chatDependencies.session.authSession.userEmail ?? ""
                )
            } ?? []

        return PersonDisplayNameResolver.displayFallbackConversationName(
            hint: conversation.displayName,
            participantEmails: participantEmails
        )
    }

    /// Whether a click on the Mac header's avatar or name opens Participants. The iOS title's
    /// tap asks the same question itself.
    private var headerOpensParticipants: Bool {
        ChatHeaderPolicy.opensParticipants(conversationType: conversation.conversationType)
    }

    /// The Mac header's avatar: the row's, from what the view model loaded or, until then,
    /// what the row already cached. Read only where the header draws an avatar.
    private var headerAvatar: ChatHeaderAvatar {
        ChatHeaderPolicy.avatar(
            conversationType: conversation.conversationType,
            participantInfo: ChatHeaderPolicy.participantInfo(
                loaded: viewModel.participantInfo,
                cached: viewModel.cachedParticipantInfo()
            ),
            fallbackDisplayText: fallbackDisplayName
        )
    }

    /// Opens Participants, a sheet (`activeDestination`). Every header control that opens it
    /// first asks whether this conversation's does.
    private func presentParticipantsList() {
        isTextFieldFocused = false
        viewModel.contactManager.showingParticipantsList = true
    }

    private var isChatActiveAndUncovered: Bool {
        Self.isChatActiveAndUncovered(
            sceneIsActive: scenePhase == .active,
            windowAppearsActive: windowAppearsActive.value,
            hasDesiredDestination: activeDestination != nil,
            hasPresentedSheet: presentedSheetDestination != nil,
            hasContactAccessPicker: viewModel.contactManager.showingContactAccessPicker,
            hasContactActionAlert: viewModel.contactManager.contactActionAlert != nil,
            hasSendErrorAlert: viewModel.sendErrorAlert != nil
        )
    }

    /// Whether someone can be looking at this chat: it gates marking newly arrived mail read
    /// (`ChatMessagesCoordinator`) and the transcript's inset shifts.
    ///
    /// `windowAppearsActive` is the Mac's half of "active" (`WindowAppearsActive`; always true on
    /// iOS). On iOS a chat is on screen only while the user is in it. On the Mac it stays in the
    /// chat column for as long as its row is selected, all day, behind whatever else is open;
    /// without this term, mail arriving then would be marked read with nobody looking.
    static func isChatActiveAndUncovered(
        sceneIsActive: Bool,
        windowAppearsActive: Bool,
        hasDesiredDestination: Bool,
        hasPresentedSheet: Bool,
        hasContactAccessPicker: Bool,
        hasContactActionAlert: Bool,
        hasSendErrorAlert: Bool
    ) -> Bool {
        sceneIsActive &&
            windowAppearsActive &&
            !hasDesiredDestination &&
            !hasPresentedSheet &&
            !hasContactAccessPicker &&
            !hasContactActionAlert &&
            !hasSendErrorAlert
    }

    static func allowsParticipantListPresentation(
        conversationType: ConversationType
    ) -> Bool {
        // List participant rows only seed the conversation from its first
        // message; presenting them as list membership would be misleading.
        conversationType != .list
    }

    /// Gates the drained auto-dismiss while a reply send still owns the
    /// composer: it would leave the conversation the optimistic row is about
    /// to anchor to, so it waits out the tap → persistence window. Archive and
    /// Report Spam wait out the same window, but a tap made in it is kept and
    /// run when the window closes (`ChatConversationExitActionPolicy`).
    static func allowsConversationExit(isSending: Bool) -> Bool {
        !isSending
    }

    /// The back button, swipe-back and the overflow menu stay available
    /// during a reply send. They used to hide/disable for the whole send, so
    /// the chevron blinked on every reply and a slow preflight (token refresh,
    /// attachments) trapped the user in the chat. Leaving is safe: the
    /// composer empties at tap, and from optimistic persistence on
    /// `OutboundTaskRegistry` and the durable graph own the send. Before
    /// persistence the send's snapshot is the only copy, and the send Task
    /// keeps the view model alive after the screen is gone; an early failure
    /// is then handed to the reopened chat's composer, or merged into the
    /// stored draft, never restored off screen (`ChatReplyComposerDirectory`,
    /// wired by `onAppear`/`onDisappear` below). Archive and Report Spam
    /// tapped before persistence run once it lands
    /// (`ChatConversationExitActionPolicy`), and a rollback never undoes an
    /// archive made meanwhile.
    static func allowsNavigationExit(isSending _: Bool) -> Bool {
        true
    }

    static func shouldDismissDrainedConversation(
        hidden: Bool,
        archivedAt: Date?,
        lastMessageDate: Date?,
        hasDraft: Bool,
        isSending: Bool
    ) -> Bool {
        ChatViewModel.isDrainedConversation(
            hidden: hidden,
            archivedAt: archivedAt,
            lastMessageDate: lastMessageDate
        ) && !hasDraft && allowsConversationExit(isSending: isSending)
    }

    private var allowsNavigationExit: Bool {
        Self.allowsNavigationExit(isSending: replySendIsInFlight)
    }

    private var shouldDismissDrainedConversation: Bool {
        Self.shouldDismissDrainedConversation(
            hidden: conversation.hidden,
            archivedAt: conversation.archivedAt,
            lastMessageDate: conversation.lastMessageDate,
            hasDraft: composerHasDraft,
            isSending: replySendIsInFlight
        )
    }

    /// Mid-send the view model holds the tap until the reply is durable
    /// instead of dropping it; the chat then closes as usual.
    private func archiveConversationAndDismiss() {
        viewModel.performConversationExitAction(.archive) { exitChat() }
    }

    private func reportSpamAndDismiss() {
        viewModel.performConversationExitAction(.reportSpam) { exitChat() }
    }

    /// The one way this chat closes itself (drained, Archive, Report Spam): through `onExit` when
    /// the presenter gave one, else by popping.
    ///
    /// On iOS the chat is pushed on a `NavigationStack` and `dismiss` pops it. In the Mac's chat
    /// column nothing was pushed: there `dismiss` closes the *window*, and closing the Mac's one
    /// window quits the app. `MacMailboxView` passes `onExit` and deselects the row instead. Keep
    /// every self-exit on this function; `ChatViewExitTests` pins that `dismiss()` is called
    /// nowhere else in this file.
    private func exitChat() {
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

    private var activeDestination: ChatDestination? {
        if let destination = viewModel.destination {
            return destination
        }

        if let wrapper = viewModel.contactManager.contactToAdd {
            return .addContact(wrapper)
        }

        if viewModel.contactManager.showingContactPicker {
            return .contactPicker
        }

        if viewModel.contactManager.showingParticipantsList {
            return .participants
        }

        return nil
    }

    private var activeDestinationBinding: Binding<ChatDestination?> {
        Binding {
            activeDestination
        } set: { newValue in
            if newValue == nil {
                dismissActiveDestination(presentationDidEnd: false)
            }
        }
    }

    @ViewBuilder
    private func destinationSheet(_ destination: ChatDestination) -> some View {
        switch destination {
        case .emailReader(let route):
            EmailReaderView(
                route: route,
                chatDependencies: chatDependencies
            )
        case .forwardCompose(let context):
            makeForwardComposeView(context)
        case .addContact(let wrapper):
            ContactsSheet(kind: .newContact(wrapper.contact))
        case .contactPicker:
            ContactsSheet(kind: .contactPicker(
                onContactSelected: { contact in
                    viewModel.contactManager.handleContactSelected(contact)
                },
                onCancel: {
                    viewModel.contactManager.handleContactPickerCancelled()
                },
                // Use name-only rows for consistent search results when picking an existing contact.
                displayedPropertyKeys: [] as [String]
            ))
        case .participants:
            ParticipantsListView(
                conversation: conversation,
                chatDependencies: chatDependencies,
                onCreateNewContact: { prefill in
                    viewModel.contactManager.createNewContact(prefill)
                },
                onAddToExistingContact: { email in
                    viewModel.contactManager.addToExistingContact(email: email)
                },
                onEditContact: { identifier in
                    viewModel.contactManager.editExistingContact(identifier: identifier)
                }
            )
        }
    }

    private func dismissActiveDestination(presentationDidEnd: Bool) {
        let dismissedDestination = presentedSheetDestination
        if presentationDidEnd {
            presentedSheetDestination = nil
        }

        // A different destination already pending means this dismissal is a sheet
        // replacement (e.g. participants -> add contact); the onDismiss belongs to
        // the outgoing sheet, so leave the incoming destination's state intact.
        if let pendingDestination = activeDestination,
           pendingDestination.id != dismissedDestination?.id {
            return
        }

        let shouldCancelContactPicker: Bool
        if case .contactPicker = dismissedDestination, viewModel.contactManager.showingContactPicker {
            shouldCancelContactPicker = true
        } else {
            shouldCancelContactPicker = false
        }

        viewModel.dismissDestination()
        viewModel.contactManager.contactToAdd = nil
        viewModel.contactManager.showingParticipantsList = false
        if shouldCancelContactPicker {
            viewModel.contactManager.handleContactPickerCancelled()
        }
    }
}
