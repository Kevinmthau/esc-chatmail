import SwiftUI
import CoreData
import ContactsUI
import UIKit

struct ChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var viewModel: ChatViewModel
    @EnvironmentObject private var deps: Dependencies

    @FetchRequest private var messages: FetchedResults<Message>
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @MainActor
    init(conversation: Conversation, deps: Dependencies? = nil) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.conversation = conversation
        self._viewModel = StateObject(wrappedValue: ChatViewModel(conversation: conversation, deps: resolvedDeps))

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
        request.predicate = NSPredicate(format: "conversation == %@ AND NOT (ANY labels.id == %@)", conversation, "DRAFT")
        request.fetchBatchSize = CoreDataConfig.fetchBatchSize
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments", "labels"]
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
            deps: deps,
            isTextFieldFocused: $isTextFieldFocused
        )
        .navigationTitle(viewModel.resolvedDisplayName ?? conversation.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewModel.resolvedDisplayName ?? conversation.displayName ?? "Chat")
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
        .sheet(item: $viewModel.messageToForward) { message in
            ComposeView(mode: .forward(message), deps: deps)
        }
        .sheet(item: $viewModel.contactManager.contactToAdd) { wrapper in
            AddContactView(contact: wrapper.contact)
        }
        .sheet(isPresented: $viewModel.contactManager.showingContactPicker) {
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
        }
        .sheet(isPresented: $viewModel.contactManager.showingParticipantsList) {
            ParticipantsListView(
                conversation: conversation,
                deps: deps,
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
    }
}
