import Foundation

/// Words and the Gmail link of the conversation list's banner for mail sync gave
/// up on: messages the cursor moved past (the escape hatch) that the abandoned
/// drain then failed to download `SyncConfig.maxAbandonedMessageRetries` times
/// (`AbandonedSyncMessage.exhaustedPredicate`). Before it, the drain deleted such
/// a row with only a log line, and the mail was missing from the app with nothing
/// to say so (architecture review 2026-11, sync-persist-path#6).
enum ExhaustedSyncMessagesPolicy {
    struct Summary: Equatable {
        let title: String
        let detail: String
        /// The message Open in Gmail shows: the one given up on first.
        let firstGmailMessageId: String
    }

    /// nil hides the banner. `gmailMessageIds` is oldest first.
    static func summary(forExhaustedMessageIds gmailMessageIds: [String]) -> Summary? {
        guard let first = gmailMessageIds.first else { return nil }
        let count = gmailMessageIds.count
        if count == 1 {
            return Summary(
                title: "1 message couldn't be downloaded",
                detail: "It is still in Gmail.",
                firstGmailMessageId: first
            )
        }
        return Summary(
            title: "\(count) messages couldn't be downloaded",
            detail: "They are still in Gmail. Open in Gmail shows the first.",
            firstGmailMessageId: first
        )
    }

    /// The message in Gmail on the web, in the account it belongs to.
    ///
    /// `authuser` picks the signed-in Google session with that address, so a
    /// browser signed in to several accounts opens the right one; without an
    /// address Gmail opens the browser's first account. The message ID is
    /// Gmail's own (the API's hex ID), never the sender's, and is put in the
    /// fragment percent-encoded all the same. Not measured: that Gmail's web
    /// app still opens a message from its API ID in `#all/<id>`.
    static func gmailWebURL(forMessageId messageId: String, accountEmail: String?) -> URL? {
        let trimmedId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty,
              trimmedId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "mail.google.com"
        components.path = "/mail/"
        if let accountEmail = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountEmail.isEmpty {
            components.queryItems = [URLQueryItem(name: "authuser", value: accountEmail)]
        }
        components.fragment = "all/\(trimmedId)"
        return components.url
    }
}
