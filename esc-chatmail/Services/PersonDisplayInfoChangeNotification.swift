import Foundation

extension Notification.Name {
    static let personDisplayInfoDidChange = Notification.Name("com.esc.inboxchat.personDisplayInfoDidChange")
}

enum PersonDisplayInfoChangeNotification {
    static let emailsUserInfoKey = "emails"

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
}
