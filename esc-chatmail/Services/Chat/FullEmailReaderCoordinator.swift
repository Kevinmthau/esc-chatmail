import Foundation

@MainActor
final class FullEmailReaderCoordinator {
    private let fullEmailOpener: any FullEmailOpening

    init(
        fullEmailOpener: (any FullEmailOpening)? = nil
    ) {
        self.fullEmailOpener = fullEmailOpener ?? FullEmailWebViewManager.shared
    }

    func openSession(for message: Message) -> FullEmailOpenSession {
        Log.info("Opening full message for \(message.id)", category: .ui)

        let request = OriginalEmailWarmRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyTextValue,
            senderEmail: message.senderEmailValue,
            subject: message.subject
        )
        let prepared = fullEmailOpener.preparedOpenArtifact(
            request: request,
            message: message,
            width: nil
        )
        let session = FullEmailOpenSession(
            message: message,
            request: request,
            initialArtifact: prepared?.artifact,
            immediatePlaceholder: FullEmailPlaceholder(message: message),
            fullEmailOpener: fullEmailOpener
        )

        if prepared == nil {
            // Backstop for a tap that beats visible-row warming. This is a fire-and-forget follow-up:
            // the session above is already presentable and does not wait for WebKit preparation.
            fullEmailOpener.prewarmOnOpen(message: message, width: nil)
        }

        return session
    }
}
