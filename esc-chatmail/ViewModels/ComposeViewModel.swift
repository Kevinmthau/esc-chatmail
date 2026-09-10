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
        case forward(ComposeForwardModeContext)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.newMessage, .newMessage): return true
            case (.newEmail, .newEmail): return true
            case (.forward(let c1), .forward(let c2)): return c1.id == c2.id
            default: return false
            }
        }
    }

    // MARK: - Published State

    @Published var subject = ""
    @Published var body = ""
    @Published var isSending = false
    @Published var errorAlert: ComposeErrorAlert?
    @Published var skippedForwardAttachmentCount = 0
    @Published private(set) var forwardedPreviewHTML: String?
    private(set) var lastSentConversationReference: ConversationReference?
    private var hasSetupMode = false
    private var forwardedPreviewIsDarkMode: Bool?

    /// Self-alias snapshot for participant-hash computation. Compose-side hashes
    /// must exclude the same alias set the sync router excludes, or a sent
    /// message and its synced-back copy land in different chats.
    private var cachedMyAliases: Set<String> = []

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Forward HTML Content

    /// HTML body content from forwarded message (nil for non-forward modes)
    private var forwardedHTMLBody: String?

    /// Plain text body of the forwarded message (used for MIME text part)
    private var forwardedPlainTextBody: String = ""

    /// Inline attachment infos from the forwarded message (images referenced by cid: URLs)
    private var forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo] = []

    // MARK: - Composed Services

    let recipientManager: RecipientManager
    let autocompleteService: ContactAutocompleteService
    let attachmentManager: ComposeAttachmentManager

    private let outboundMessageCoordinator: any OutboundMessageCoordinating
    private let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder

    // MARK: - Dependencies

    let mode: Mode
    private let storage: StorageDependencies

    // MARK: - Computed Properties

    var recipients: [Recipient] { recipientManager.recipients }
    var recipientInput: String {
        get { recipientManager.recipientInput }
        set {
            guard !isSending else { return }
            recipientManager.recipientInput = newValue
        }
    }
    var attachments: [Attachment] { attachmentManager.attachments }
    var isImportingAttachments: Bool { attachmentManager.isImportingAttachments }
    var autocompleteContacts: [ContactsService.ContactMatch] { autocompleteService.autocompleteContacts }
    var showAutocomplete: Bool { autocompleteService.showAutocomplete }
    var isForwardMode: Bool {
        if case .forward = mode { return true }
        return false
    }
    var forwardedPreviewText: String { forwardedPlainTextBody }

    var canSend: Bool {
        let hasValidRecipients = !recipients.isEmpty && recipients.allSatisfy { $0.isValid }
        guard hasValidRecipients,
              !isSending,
              !isImportingAttachments,
              attachments.allSatisfy(Self.isAttachmentReadyToSend) else {
            return false
        }

        switch mode {
        case .forward:
            return true
        case .newMessage, .newEmail:
            return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var showSubjectField: Bool {
        switch mode {
        case .newEmail, .forward: return true
        case .newMessage: return false
        }
    }

    var navigationTitle: String {
        switch mode {
        case .newMessage, .newEmail: return "New Message"
        case .forward: return "Forward"
        }
    }

    // MARK: - Initialization

    init(mode: Mode = .newMessage, dependencies: ComposeDependencies? = nil) {
        let resolvedDependencies = dependencies ?? Dependencies.shared.makeComposeDependencies()
        self.mode = mode
        self.storage = resolvedDependencies.storage

        // Initialize composed services
        self.recipientManager = resolvedDependencies.makeRecipientManager()
        self.autocompleteService = resolvedDependencies.makeContactAutocompleteService()
        self.attachmentManager = resolvedDependencies.makeComposeAttachmentManager()
        self.outboundMessageCoordinator = resolvedDependencies.messaging.makeOutboundMessageCoordinator()
        self.outboundAttachmentContextBuilder = resolvedDependencies.messaging.makeOutboundAttachmentContextBuilder()

        // Forward child observable changes to trigger view updates
        forwardChanges(from: autocompleteService, storing: &cancellables)
        forwardChanges(from: recipientManager, storing: &cancellables)
        forwardChanges(from: attachmentManager, storing: &cancellables)

        Task { [weak self] in
            // getAliases(from:) falls back to Core Data on a cold cache; a
            // cached-only read would leave lookups without self-exclusion
            // until the first sync primes AliasManager.
            guard let context = self?.storage.viewContext else { return }
            let aliases = await AliasManager.shared.getAliases(from: context)
            self?.cachedMyAliases = aliases
        }
    }

    func setupForMode() {
        guard !hasSetupMode else { return }
        hasSetupMode = true

        switch mode {
        case .forward(let context):
            body = ""
            subject = context.initialSubject ?? ""

            // Store HTML content for forwarding
            forwardedHTMLBody = context.forwardedHTMLBody
            forwardedPlainTextBody = context.forwardedPlainTextBody

            // Store inline attachments for forwarding (these will be included in multipart/related)
            forwardedInlineAttachmentInfos = context.forwardedInlineAttachmentInfos

            // Copy regular attachments from original message
            var skipped = 0
            for attachment in context.forwardedRegularAttachments {
                if let copied = attachmentManager.copyAttachmentForForward(attachment) {
                    attachmentManager.addAttachment(copied)
                } else {
                    skipped += 1
                }
            }
            skippedForwardAttachmentCount = skipped
        case .newMessage, .newEmail:
            break
        }
    }

    func updateForwardedPreviewHTML(isDarkMode: Bool) {
        guard let forwardedHTMLBody else {
            forwardedPreviewIsDarkMode = nil
            if forwardedPreviewHTML != nil {
                forwardedPreviewHTML = nil
            }
            return
        }

        guard forwardedPreviewHTML == nil || forwardedPreviewIsDarkMode != isDarkMode else {
            return
        }

        let wrappedHTML = HTMLSanitizerService.shared.wrapHTMLForDisplay(
            forwardedHTMLBody,
            isDarkMode: isDarkMode,
            displayPurpose: .preview
        )
        forwardedPreviewIsDarkMode = isDarkMode
        forwardedPreviewHTML = wrappedHTML
    }

    // MARK: - Delegate Methods (passthrough to services)

    func requestContactsAccess() async {
        await autocompleteService.requestAccess()
    }

    func addRecipient(_ recipient: Recipient) {
        guard !isSending else { return }
        recipientManager.addRecipient(recipient)
    }

    func addRecipient(email: String, displayName: String? = nil) {
        guard !isSending else { return }
        recipientManager.addRecipient(email: email, displayName: displayName)
    }

    func removeRecipient(_ recipient: Recipient) {
        guard !isSending else { return }
        recipientManager.removeRecipient(recipient)
    }

    func addRecipientFromInput() {
        guard !isSending else { return }
        if recipientManager.addRecipientFromInput() {
            autocompleteService.clearAutocomplete()
        }
    }

    func searchContacts(query: String) {
        autocompleteService.searchContacts(query: query)
    }

    func selectContact(_ contact: ContactsService.ContactMatch, email: String? = nil) {
        guard !isSending else { return }
        let result = autocompleteService.selectContact(contact, email: email)
        recipientManager.addRecipient(email: result.email, displayName: result.displayName)
        recipientManager.recipientInput = ""
    }

    func clearAutocomplete() {
        autocompleteService.clearAutocomplete()
    }

    func findActiveConversation(forRecipients recipients: [String]) -> Conversation? {
        ConversationLookupService(context: storage.viewContext)
            .findActiveConversation(forRecipients: recipients, myAliases: cachedMyAliases)
    }

    func addAttachment(_ attachment: Attachment) {
        guard !isSending else { return }
        attachmentManager.addAttachment(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        guard !isSending else { return }
        attachmentManager.removeAttachment(attachment)
    }

    func setAttachmentImportInProgress(_ isInProgress: Bool, id: UUID) {
        attachmentManager.setImportInProgress(isInProgress, id: id)
    }

    // MARK: - Send Message

    func send() async -> Bool {
        lastSentConversationReference = nil
        guard canSend else { return false }

        isSending = true
        errorAlert = nil

        let result: OutboundMessageResult?
        do {
            let recipientEmails = recipients.map { $0.email }
            result = try await outboundMessageCoordinator.send(preparing: { [self] in
                let myAliases = await AliasManager.shared.getAliases(from: storage.viewContext)
                cachedMyAliases = myAliases
                return try makeOutboundSendRequest(
                    recipientEmails: recipientEmails,
                    myAliases: myAliases
                )
            })
        } catch {
            Log.error("Failed to create optimistic message", category: .message, error: error)
            errorAlert = ComposeErrorAlert(message: error.localizedDescription)
            isSending = false
            return false
        }
        guard let result else {
            isSending = false
            return false
        }

        lastSentConversationReference = result.conversationReference
        isSending = false
        return true
    }

    private func makeOutboundSendRequest(recipientEmails: [String], myAliases: Set<String>) throws -> OutboundMessageRequest {
        switch mode {
        case .newMessage, .newEmail:
            return .compose(
                .init(
                    recipientEmails: recipientEmails,
                    subject: subject,
                    body: body,
                    attachments: try outboundAttachmentContextBuilder.buildSendAttachments(from: attachments),
                    optimisticConversation: makeOptimisticConversationReference(forRecipients: recipientEmails, myAliases: myAliases)
                )
            )

        case .forward:
            return .forward(
                .init(
                    recipientEmails: recipientEmails,
                    subject: subject,
                    body: body,
                    attachments: try outboundAttachmentContextBuilder.buildSendAttachments(from: attachments),
                    forwardedPlainTextBody: forwardedPlainTextBody,
                    forwardedHTMLBody: forwardedHTMLBody,
                    forwardedInlineAttachmentInfos: forwardedInlineAttachmentInfos,
                    optimisticConversation: makeOptimisticConversationReference(forRecipients: recipientEmails, myAliases: myAliases)
                )
            )

        }
    }

    private static func isAttachmentReadyToSend(_ attachment: Attachment) -> Bool {
        guard let localURL = attachment.localURLValue else { return false }
        return !localURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeOptimisticConversationReference(
        forRecipients recipients: [String],
        myAliases: Set<String>
    ) -> OptimisticConversationReference? {
        guard let identity = makeRecipientParticipantSetIdentity(
            recipients: recipients,
            myAliases: myAliases
        ) else { return nil }

        return .participantHash(identity.participantHash)
    }
}

struct ComposeErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}
