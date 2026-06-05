import SwiftUI
import UIKit

struct FullEmailReaderView: View {
    @ObservedObject var session: FullEmailOpenSession
    @Environment(\.dismiss) private var dismiss
    /// The already-rendered chat preview snapshot, shown instantly until the live WebView confirms paint.
    @State private var snapshotPlaceholder: UIImage?
    /// Set once the live WebView reports paint-confirmed readiness, cross-fading the snapshot away.
    @State private var webViewPainted = false
    @State private var loadedContentSignature: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Original Email")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification)) { notification in
            session.reloadIfRemoteImageFallbackWarmed(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: HTMLContentLoader.contentSourceDidChangeNotification)) { notification in
            session.reloadIfContentSourceChanged(notification)
        }
        .task(id: session.loadKey) {
            await session.loadReaderContent()
        }
        .task(id: session.messageId) {
            await loadSnapshotPlaceholder()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.readerState {
        case .preparedHTML(let payload, placeholder: _):
            loadedHTMLContent(html: payload.html, sourceSignature: payload.sourceSignature)
        case .loading(let placeholder):
            loadingContent(placeholder: placeholder, isRecovering: false)
        case .recovering(let placeholder):
            loadingContent(placeholder: placeholder, isRecovering: true)
        case .loadedHTML(let html, let sourceSignature, placeholder: _):
            loadedHTMLContent(html: html, sourceSignature: sourceSignature)
        case .loadedPlainText(let text):
            OriginalEmailReadableView(message: session.message, text: text)
        case .retryableFailure(let placeholder, reason: _):
            failureContent(placeholder: placeholder, allowsRetry: true)
        case .unrecoverableFailure(let placeholder, reason: _):
            failureContent(placeholder: placeholder, allowsRetry: false)
        }
    }

    /// Loading/recovering: if the rendered chat preview snapshot is already available, show it
    /// immediately so the email appears instantly instead of a bare spinner. With cache warming the
    /// load usually resolves within a frame or two; this mainly covers cold/slow opens.
    @ViewBuilder
    private func loadingContent(placeholder: FullEmailPlaceholder, isRecovering: Bool) -> some View {
        if let snapshotPlaceholder {
            snapshotPlaceholderView(snapshotPlaceholder)
                .overlay(alignment: .bottom) {
                    loadingBanner(text: FullEmailPlaceholderOverlayState.resolving(isRecovering: isRecovering).text)
                }
        } else {
            FullEmailPlaceholderSurface(
                placeholder: placeholder,
                overlayState: .resolving(isRecovering: isRecovering)
            )
        }
    }

    /// Loaded HTML: render the interactive WebView, covering its paint gap with the snapshot
    /// placeholder and cross-fading the placeholder out once the WebView reports paint-confirmed readiness.
    @ViewBuilder
    private func loadedHTMLContent(html: String, sourceSignature: String?) -> some View {
        let contentSignature = loadedHTMLContentSignature(for: html, sourceSignature: sourceSignature)
        ZStack {
            HTMLMessageView(
                message: session.message,
                html: html,
                sourceSignature: sourceSignature,
                onLoadFinished: handleWebViewPainted,
                onAdoptedPrerendered: handleAdoptedPrerendered
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let snapshotPlaceholder, !webViewPainted {
                snapshotPlaceholderView(snapshotPlaceholder)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            handleLoadedContentSignature(contentSignature)
        }
        .onChange(of: contentSignature) { _, newSignature in
            handleLoadedContentSignature(newSignature)
        }
    }

    @ViewBuilder
    private func failureContent(placeholder: FullEmailPlaceholder, allowsRetry: Bool) -> some View {
        if let snapshotPlaceholder {
            // Never dead-end on a blank "Unavailable" card when the rendered preview is still on hand.
            snapshotPlaceholderView(snapshotPlaceholder)
                .overlay(alignment: .bottom) {
                    if allowsRetry {
                        Button {
                            session.retry()
                        } label: {
                            SwiftUI.Label("Reload full email", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 20)
                    }
                }
        } else {
            FullEmailPlaceholderSurface(
                placeholder: placeholder,
                overlayState: .failure(allowsRetry: allowsRetry),
                retryAction: allowsRetry ? { session.retry() } : nil
            )
        }
    }

    private func snapshotPlaceholderView(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func loadingBanner(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 20)
    }

    private func handleWebViewPainted() {
        guard !webViewPainted else {
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            webViewPainted = true
        }
    }

    /// A pre-rendered WebView was adopted, so the email is already painted and no masking is needed.
    private func handleAdoptedPrerendered() {
        webViewPainted = true
    }

    private func loadSnapshotPlaceholder() async {
        guard snapshotPlaceholder == nil,
              let metadata = await RenderedMessageCache.shared.latestSnapshotMetadata(messageId: session.message.id),
              let entry = await EmailPreviewSnapshotCache.shared.load(for: metadata.snapshotCacheKey),
              let image = UIImage(data: entry.imageData),
              !Task.isCancelled else {
            return
        }
        snapshotPlaceholder = image
        if !session.readerState.hasLoadedContent {
            session.reloadPreservingContent()
        }
    }

    private func loadedHTMLContentSignature(for html: String, sourceSignature: String?) -> String {
        let htmlSignature = CanonicalEmailContent(
            html: html,
            plainText: nil,
            sourceKind: .html,
            sourceLocation: .messageFile
        ).sourceSignature
        return [
            sourceSignature ?? "source:nil",
            htmlSignature
        ].joined(separator: "|")
    }

    private func handleLoadedContentSignature(_ signature: String) {
        guard loadedContentSignature != signature else {
            return
        }

        loadedContentSignature = signature
        webViewPainted = false
    }
}

enum FullEmailPlaceholderOverlayState: Equatable {
    case loading(String)
    case message(String)

    static func resolving(isRecovering: Bool) -> FullEmailPlaceholderOverlayState {
        .loading(isRecovering ? "Recovering original email…" : "Loading full email…")
    }

    static func failure(allowsRetry: Bool) -> FullEmailPlaceholderOverlayState? {
        allowsRetry ? nil : .message("Original email unavailable")
    }

    var text: String {
        switch self {
        case .loading(let text), .message(let text):
            return text
        }
    }

    var showsProgress: Bool {
        switch self {
        case .loading:
            return true
        case .message:
            return false
        }
    }
}

private struct FullEmailPlaceholderSurface: View {
    let placeholder: FullEmailPlaceholder
    let overlayState: FullEmailPlaceholderOverlayState?
    var retryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(placeholder.senderDisplayText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    if let date = placeholder.date {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(placeholder.subject)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if let previewText = placeholder.previewText {
                Text(previewText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            overlay
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let retryAction {
            Button {
                retryAction()
            } label: {
                SwiftUI.Label("Reload full email", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 20)
        } else if let overlayState {
            HStack(spacing: 8) {
                if overlayState.showsProgress {
                    ProgressView().controlSize(.small)
                }
                Text(overlayState.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 20)
        }
    }
}

private struct OriginalEmailReadableView: View {
    let message: Message
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OriginalEmailMetadataCard(message: message)

                Text(Self.linkifiedAttributedString(from: text))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(.blue)
    }

    private static func linkifiedAttributedString(from text: String) -> AttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        )

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: attributed.length)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url else {
                    continue
                }
                attributed.addAttribute(.link, value: url, range: match.range)
            }
        }

        return AttributedString(attributed)
    }
}

enum OriginalEmailMetadataFormatter {
    static func senderLine(senderName: String?, senderEmail: String?) -> String? {
        let trimmedName = senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = senderEmail?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedEmail, !trimmedEmail.isEmpty {
            guard let trimmedName, !trimmedName.isEmpty else {
                return trimmedEmail
            }

            if let extractedEmail = EmailNormalizer.extractEmail(from: trimmedName),
               EmailNormalizer.normalize(extractedEmail) == EmailNormalizer.normalize(trimmedEmail) {
                return trimmedName
            }

            if EmailNormalizer.normalize(trimmedName) == EmailNormalizer.normalize(trimmedEmail) {
                return trimmedEmail
            }

            return "\(trimmedName) <\(trimmedEmail)>"
        }

        guard let trimmedName, !trimmedName.isEmpty else {
            return PersonDisplayNameResolver.fallbackSenderName()
        }

        return trimmedName
    }
}

private struct OriginalEmailMetadataCard: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let subject = message.subject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !subject.isEmpty {
                Text(subject)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            if let senderLine, !senderLine.isEmpty {
                Text(senderLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(message.internalDate.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var senderLine: String? {
        OriginalEmailMetadataFormatter.senderLine(
            senderName: message.senderName,
            senderEmail: message.senderEmail
        )
    }
}
