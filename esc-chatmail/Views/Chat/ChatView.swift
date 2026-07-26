import SwiftUI
import CoreData
import ContactsUI
import UIKit

struct ChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var viewModel: ChatViewModel
    @State private var presentedSheetDestination: ChatDestination?
    @State private var composerHasDraft = false
    private let chatDependencies: ChatDependencies
    private let makeForwardComposeView: @MainActor (ComposeForwardModeContext) -> ComposeView

    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(
        conversation: Conversation,
        chatDependencies: ChatDependencies,
        makeForwardComposeView: @escaping @MainActor (ComposeForwardModeContext) -> ComposeView = { context in
            ComposeView(mode: .forward(context))
        }
    ) {
        self.conversation = conversation
        self.chatDependencies = chatDependencies
        self.makeForwardComposeView = makeForwardComposeView
        self._viewModel = StateObject(
            wrappedValue: ChatViewModel(conversation: conversation, chatDependencies: chatDependencies)
        )
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            content
                .contactAccessPicker(isPresented: $viewModel.contactManager.showingContactAccessPicker) { identifiers in
                    viewModel.contactManager.handleContactAccessPickerCompletion(identifiers)
                }
        } else {
            content
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
        .navigationTitle(navigationDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
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
                        isTextFieldFocused = false
                        viewModel.contactManager.showingParticipantsList = true
                    }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: {
                        viewModel.archiveConversation()
                        dismiss()
                    }) {
                        SwiftUI.Label("Archive", systemImage: "archivebox")
                    }

                    Button(action: {
                        viewModel.reportSpam()
                        dismiss()
                    }) {
                        SwiftUI.Label("Report Spam", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: activeDestinationBinding, onDismiss: {
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
                        if let url = URL(string: UIApplication.openSettingsURLString) {
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
                    message: Text("ESC Chatmail has limited Contacts access. To edit \(contactName), allow access to it in the next sheet."),
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
                title: Text("Couldn’t Send Reply"),
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
        .onChange(of: shouldDismissDrainedConversation, initial: true) { _, shouldDismiss in
            guard shouldDismiss else { return }
            isTextFieldFocused = false
            dismiss()
        }
    }

    private var navigationDisplayName: String {
        if let displayNameForNavigation = viewModel.displayNameForNavigation {
            return displayNameForNavigation
        }

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

    private var isChatActiveAndUncovered: Bool {
        Self.isChatActiveAndUncovered(
            sceneIsActive: scenePhase == .active,
            hasDesiredDestination: activeDestination != nil,
            hasPresentedSheet: presentedSheetDestination != nil,
            hasContactAccessPicker: viewModel.contactManager.showingContactAccessPicker,
            hasContactActionAlert: viewModel.contactManager.contactActionAlert != nil,
            hasSendErrorAlert: viewModel.sendErrorAlert != nil
        )
    }

    static func isChatActiveAndUncovered(
        sceneIsActive: Bool,
        hasDesiredDestination: Bool,
        hasPresentedSheet: Bool,
        hasContactAccessPicker: Bool,
        hasContactActionAlert: Bool,
        hasSendErrorAlert: Bool
    ) -> Bool {
        sceneIsActive &&
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

    static func shouldDismissDrainedConversation(
        hidden: Bool,
        archivedAt: Date?,
        lastMessageDate: Date?,
        hasDraft: Bool
    ) -> Bool {
        ChatViewModel.isDrainedConversation(
            hidden: hidden,
            archivedAt: archivedAt,
            lastMessageDate: lastMessageDate
        ) && !hasDraft
    }

    private var shouldDismissDrainedConversation: Bool {
        Self.shouldDismissDrainedConversation(
            hidden: conversation.hidden,
            archivedAt: conversation.archivedAt,
            lastMessageDate: conversation.lastMessageDate,
            hasDraft: composerHasDraft
        )
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
            AddContactView(contact: wrapper.contact)
        case .contactPicker:
            ContactPickerView(
                onContactSelected: { contact in
                    viewModel.contactManager.handleContactSelected(contact)
                },
                onCancel: {
                    viewModel.contactManager.handleContactPickerCancelled()
                },
                // Use name-only rows for consistent search results when picking an existing contact.
                displayedPropertyKeys: [] as [String]
            )
        case .participants:
            ParticipantsListView(
                conversation: conversation,
                chatDependencies: chatDependencies,
                onCreateNewContact: { person in
                    viewModel.contactManager.createNewContact(for: person)
                },
                onAddToExistingContact: { person in
                    viewModel.contactManager.addToExistingContact(for: person)
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
