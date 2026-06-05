import SwiftUI
import CoreData
import ContactsUI
import UIKit

struct ChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var viewModel: ChatViewModel
    private let chatDependencies: ChatDependencies
    private let makeForwardComposeView: @MainActor (ComposeForwardModeContext) -> ComposeView

    @FetchRequest private var messages: FetchedResults<Message>
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
        request.predicate = MessagePredicates.visibleInChat(conversation: conversation)
        request.fetchBatchSize = CoreDataConfig.fetchBatchSize
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments", "labels"]
        request.includesPendingChanges = true
        self._messages = FetchRequest(fetchRequest: request)
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
            messages: messages,
            viewModel: viewModel,
            chatDependencies: chatDependencies,
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
            dismissActiveDestination()
        }) { destination in
            destinationSheet(destination)
        }
        .alert(item: $viewModel.contactManager.contactActionAlert) { alert in
            switch alert.kind {
            case .contactsDenied:
                Alert(
                    title: Text("Contacts Access Needed"),
                    message: Text("Allow Contacts access in Settings to add this email to an existing contact."),
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
    }

    private var navigationDisplayName: String {
        if let resolvedDisplayName = viewModel.resolvedDisplayName {
            return resolvedDisplayName
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

        return PersonDisplayNameResolver.sanitizedConversationDisplayNameHint(
            conversation.displayName,
            participantEmails: participantEmails
        ) ?? PersonDisplayNameResolver.fallbackConversationName(
            participantEmails: participantEmails
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
                dismissActiveDestination()
            }
        }
    }

    @ViewBuilder
    private func destinationSheet(_ destination: ChatDestination) -> some View {
        switch destination {
        case .emailReader(let route):
            EmailReaderView(
                route: route,
                chatDependencies: chatDependencies,
                onReply: {
                    viewModel.setReplyingTo(messageObjectID: route.messageObjectID)
                    viewModel.dismissDestination()
                },
                onForward: {
                    viewModel.setMessageToForward(messageObjectID: route.messageObjectID)
                }
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

    private func dismissActiveDestination() {
        viewModel.dismissDestination()
        viewModel.contactManager.contactToAdd = nil
        viewModel.contactManager.showingParticipantsList = false
        if viewModel.contactManager.showingContactPicker {
            viewModel.contactManager.handleContactPickerCancelled()
        }
    }
}
