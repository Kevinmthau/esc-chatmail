import Foundation
import CoreData
import Combine
import Contacts

/// Centralized ViewModel for message composition
/// Consolidates logic from NewMessageComposerView and NewMessageView
@MainActor
final class ComposeViewModel: ObservableObject {

    // MARK: - Compose Mode

    enum Mode: Equatable {
        case newMessage
        case newEmail // includes subject field
        case forward(Message)
        case reply(Conversation, Message?)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.newMessage, .newMessage): return true
            case (.newEmail, .newEmail): return true
            case (.forward(let m1), .forward(let m2)): return m1.objectID == m2.objectID
            case (.reply(let c1, let m1), .reply(let c2, let m2)):
                return c1.objectID == c2.objectID && m1?.objectID == m2?.objectID
            default: return false
            }
        }
    }

    // MARK: - Published State

    @Published var subject = ""
    @Published var body = ""
    @Published var isSending = false
    @Published var error: Error?
    @Published var showError = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Composed Services

    let recipientManager: RecipientManager
    let autocompleteService: ContactAutocompleteService
    let attachmentManager: ComposeAttachmentManager

    private let replyMetadataBuilder: ReplyMetadataBuilder
    private let messageFormatBuilder: MessageFormatBuilder

    // MARK: - Dependencies

    let mode: Mode
    private let dependencies: Dependencies
    private var syncEngine: SyncEngine { dependencies.syncEngine }
    private lazy var sendService: GmailSendService = dependencies.makeSendService()

    // MARK: - Computed Properties

    var recipients: [Recipient] { recipientManager.recipients }
    var recipientInput: String {
        get { recipientManager.recipientInput }
        set { recipientManager.recipientInput = newValue }
    }
    var attachments: [Attachment] { attachmentManager.attachments }
    var autocompleteContacts: [ContactsService.ContactMatch] { autocompleteService.autocompleteContacts }
    var showAutocomplete: Bool { autocompleteService.showAutocomplete }

    var canSend: Bool {
        !recipients.isEmpty &&
        recipients.allSatisfy { $0.isValid } &&
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSending
    }

    var showSubjectField: Bool {
        switch mode {
        case .newEmail, .forward: return true
        case .newMessage, .reply: return false
        }
    }

    var navigationTitle: String {
        switch mode {
        case .newMessage, .newEmail: return "New Message"
        case .forward: return "Forward"
        case .reply: return "Reply"
        }
    }

    // MARK: - Initialization

    init(mode: Mode = .newMessage, deps: Dependencies? = nil) {
        let resolvedDeps = deps ?? .shared
        self.mode = mode
        self.dependencies = resolvedDeps

        // Initialize composed services
        self.recipientManager = RecipientManager(authSession: resolvedDeps.authSession)
        self.autocompleteService = ContactAutocompleteService()
        self.attachmentManager = ComposeAttachmentManager(viewContext: resolvedDeps.coreDataStack.viewContext)
        self.replyMetadataBuilder = ReplyMetadataBuilder(authSession: resolvedDeps.authSession)
        self.messageFormatBuilder = MessageFormatBuilder(authSession: resolvedDeps.authSession)

        // Forward child observable changes to trigger view updates
        autocompleteService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        recipientManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func setupForMode() {
        switch mode {
        case .forward(let message):
            let result = messageFormatBuilder.formatForwardedMessage(message)
            body = result.body
            subject = result.subject ?? ""

            // Copy attachments from original message
            for original in result.attachments {
                if let copied = attachmentManager.copyAttachmentForForward(original) {
                    attachmentManager.addAttachment(copied)
                }
            }
        case .reply(let conversation, _):
            recipientManager.setupReplyRecipients(from: conversation)
        case .newMessage, .newEmail:
            break
        }
    }

    // MARK: - Delegate Methods (passthrough to services)

    func requestContactsAccess() async {
        await autocompleteService.requestAccess()
    }

    func addRecipient(_ recipient: Recipient) {
        recipientManager.addRecipient(recipient)
    }

    func addRecipient(email: String, displayName: String? = nil) {
        recipientManager.addRecipient(email: email, displayName: displayName)
    }

    func removeRecipient(_ recipient: Recipient) {
        recipientManager.removeRecipient(recipient)
    }

    func addRecipientFromInput() {
        if recipientManager.addRecipientFromInput() {
            autocompleteService.clearAutocomplete()
        }
    }

    func searchContacts(query: String) {
        autocompleteService.searchContacts(query: query)
    }

    func selectContact(_ contact: ContactsService.ContactMatch, email: String? = nil) {
        let result = autocompleteService.selectContact(contact, email: email)
        recipientManager.addRecipient(email: result.email, displayName: result.displayName)
        recipientManager.recipientInput = ""
    }

    func clearAutocomplete() {
        autocompleteService.clearAutocomplete()
    }

    func addAttachment(_ attachment: Attachment) {
        attachmentManager.addAttachment(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        attachmentManager.removeAttachment(attachment)
    }

    // MARK: - Send Message

    func send() async -> Bool {
        guard canSend else { return false }

        isSending = true
        error = nil

        let recipientEmails = recipients.map { $0.email }
        let messageBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageSubject = subject.isEmpty ? nil : subject

        // Create optimistic message
        let optimisticMessage = await sendService.createOptimisticMessage(
            to: recipientEmails,
            body: messageBody,
            subject: messageSubject,
            attachments: attachments
        )
        let optimisticMessageID = optimisticMessage.id

        // Prepare attachment infos for background send
        let attachmentInfos = attachments.map { sendService.attachmentToInfo($0) }

        // Build reply data on main actor before background task (Core Data objects aren't Sendable)
        let orchestratorReplyData: ComposeSendOrchestrator.SendInput.ReplyData?
        switch mode {
        case .reply(let conversation, let replyingTo):
            let replyData = replyMetadataBuilder.buildReplyData(
                conversation: conversation,
                replyingTo: replyingTo,
                body: messageBody
            )
            orchestratorReplyData = ComposeSendOrchestrator.SendInput.ReplyData(
                recipients: replyData.recipients,
                body: replyData.body,
                subject: replyData.subject,
                threadId: replyData.threadId,
                inReplyTo: replyData.inReplyTo,
                references: replyData.references,
                originalMessage: replyData.originalMessage
            )
        default:
            orchestratorReplyData = nil
        }

        let input = ComposeSendOrchestrator.SendInput(
            recipientEmails: recipientEmails,
            body: messageBody,
            subject: messageSubject,
            attachmentInfos: attachmentInfos,
            replyData: orchestratorReplyData
        )

        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncEngine: syncEngine)
        orchestrator.executeInBackground(
            input: input,
            attachments: Array(attachments),
            optimisticMessageID: optimisticMessageID
        )

        isSending = false
        return true
    }
}
