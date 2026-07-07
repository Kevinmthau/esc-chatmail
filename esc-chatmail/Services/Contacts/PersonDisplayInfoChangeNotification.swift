import Foundation
import CoreData

extension Notification.Name {
    static let personDisplayInfoDidChange = Notification.Name("com.esc.inboxchat.personDisplayInfoDidChange")
}

enum PersonDisplayInfoChangeNotification {
    static let emailsUserInfoKey = "emails"
    private static let pendingContextSaveEmailsUserInfoKey = "personDisplayInfoDidChange.pendingEmails"
    private static let contextSaveObserverUserInfoKey = "personDisplayInfoDidChange.contextSaveObserver"

    static func post(
        emails: some Sequence<String>,
        notificationCenter: NotificationCenter = .default
    ) {
        let normalizedEmails = normalizedEmailSet(from: emails)
        guard !normalizedEmails.isEmpty else { return }

        notificationCenter.post(
            name: .personDisplayInfoDidChange,
            object: nil,
            userInfo: [emailsUserInfoKey: Array(normalizedEmails).sorted()]
        )
    }

    /// Posts a display-info change with no email scope. Observers treat an
    /// empty change-set as "refresh everything" — used when contacts
    /// authorization changes and every resolved name/photo may be stale.
    /// (`post(emails:)` refuses empty sets, so this is the only broadcast path.)
    static func postAllChanged(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: .personDisplayInfoDidChange, object: nil)
    }

    static func invalidatePersonCacheAndPost(emails: some Sequence<String>) async {
        let normalizedEmails = normalizedEmailSet(from: emails)
        guard !normalizedEmails.isEmpty else { return }

        for email in normalizedEmails {
            await PersonCache.shared.invalidateEntry(for: email)
        }

        post(emails: normalizedEmails)
    }

    static func invalidatePersonCacheAndPostLater(emails: some Sequence<String>) {
        let normalizedEmails = normalizedEmailSet(from: emails)
        guard !normalizedEmails.isEmpty else { return }

        Task {
            await invalidatePersonCacheAndPost(emails: normalizedEmails)
        }
    }

    static func invalidatePersonCacheAndPostAfterContextSave(
        emails: some Sequence<String>,
        in context: NSManagedObjectContext
    ) {
        let normalizedEmails = normalizedEmailSet(from: emails)
        guard !normalizedEmails.isEmpty else { return }

        let existingEmails = normalizedEmailSet(
            from: context.userInfo[pendingContextSaveEmailsUserInfoKey] as? [String] ?? []
        )
        context.userInfo[pendingContextSaveEmailsUserInfoKey] = Array(
            existingEmails.union(normalizedEmails)
        ).sorted()

        if context.userInfo[contextSaveObserverUserInfoKey] == nil {
            context.userInfo[contextSaveObserverUserInfoKey] = PendingPersonDisplayInfoSaveObserver(
                context: context
            )
        }
    }

    static func emails(from notification: Notification) -> Set<String> {
        guard let values = notification.userInfo?[emailsUserInfoKey] as? [String] else {
            return []
        }

        return normalizedEmailSet(from: values)
    }

    private static func normalizedEmailSet(from emails: some Sequence<String>) -> Set<String> {
        Set(
            emails
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
    }

    fileprivate static func takePendingContextSaveEmails(from context: NSManagedObjectContext) -> Set<String> {
        defer {
            context.userInfo.removeObject(forKey: pendingContextSaveEmailsUserInfoKey)
            context.userInfo.removeObject(forKey: contextSaveObserverUserInfoKey)
        }

        return normalizedEmailSet(
            from: context.userInfo[pendingContextSaveEmailsUserInfoKey] as? [String] ?? []
        )
    }
}

private final class PendingPersonDisplayInfoSaveObserver: NSObject {
    private weak var context: NSManagedObjectContext?

    init(context: NSManagedObjectContext) {
        self.context = context
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: context
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contextDidSave(_ _: Notification) {
        guard let context else { return }

        let emails = PersonDisplayInfoChangeNotification.takePendingContextSaveEmails(from: context)
        NotificationCenter.default.removeObserver(self)
        PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPostLater(emails: emails)
    }
}
