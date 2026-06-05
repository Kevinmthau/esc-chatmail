import CoreGraphics
import Foundation

@MainActor
final class FullEmailReaderCoordinator {
    private let fullEmailOpener: any FullEmailOpening
    private let widthProvider: @MainActor () -> CGFloat

    init(
        fullEmailOpener: (any FullEmailOpening)? = nil,
        widthProvider: (@MainActor () -> CGFloat)? = nil
    ) {
        self.fullEmailOpener = fullEmailOpener ?? FullEmailWebViewManager.shared
        self.widthProvider = widthProvider ?? { FullEmailWebViewMetrics.fullViewWidth() }
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
        let payload = fullEmailOpener.preparedOpenPayload(
            request: request,
            message: message,
            width: widthProvider()
        )
        let session = FullEmailOpenSession(
            message: message,
            request: request,
            initialOpenPayload: payload,
            immediatePlaceholder: FullEmailPlaceholder(message: message)
        )

        if payload == nil {
            // Backstop for a tap that beats visible-row warming. This is a fire-and-forget follow-up:
            // the session above is already presentable and does not wait for WebKit preparation.
            fullEmailOpener.prewarmOnOpen(message: message)
        }

        return session
    }
}
