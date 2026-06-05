import SwiftUI
import UIKit

struct FullEmailReaderView: View {
    @ObservedObject var session: FullEmailOpenSession
    let mode: EmailReaderMode
    let availableModes: [EmailReaderMode]
    let onModeSelected: (EmailReaderMode) -> Void
    let onReply: (() -> Void)?
    let onForward: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    /// The already-rendered chat preview snapshot, shown instantly until the live WebView confirms paint.
    @State private var snapshotPlaceholder: UIImage?
    /// Set once the live WebView reports paint-confirmed readiness, cross-fading the snapshot away.
    @State private var webViewPainted = false
    @State private var loadedContentSignature: String?

    init(
        session: FullEmailOpenSession,
        mode: EmailReaderMode = .original,
        availableModes: [EmailReaderMode] = [.original],
        onModeSelected: @escaping (EmailReaderMode) -> Void = { _ in },
        onReply: (() -> Void)? = nil,
        onForward: (() -> Void)? = nil
    ) {
        self.session = session
        self.mode = mode
        self.availableModes = availableModes
        self.onModeSelected = onModeSelected
        self.onReply = onReply
        self.onForward = onForward
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EmailReaderMetadataChrome(
                    message: session.message,
                    mode: mode,
                    availableModes: availableModes,
                    onModeSelected: onModeSelected,
                    onReply: onReply.map { reply in
                        {
                            reply()
                            dismiss()
                        }
                    },
                    onForward: onForward
                )

                Divider()

                content
            }
                .navigationTitle("Email")
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
            OriginalEmailReadableView(text: text)
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
    let text: String

    var body: some View {
        ScrollView {
            Text(Self.linkifiedAttributedString(from: text))
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(18)
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

private struct EmailReaderMetadataChrome: View {
    let message: Message
    let mode: EmailReaderMode
    let availableModes: [EmailReaderMode]
    let onModeSelected: (EmailReaderMode) -> Void
    let onReply: (() -> Void)?
    let onForward: (() -> Void)?

    @State private var showingRecipients = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(subject)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                modeControl
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(senderLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(message.internalDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                actionButtons
            }

            if let recipientSummary {
                DisclosureGroup(isExpanded: $showingRecipients) {
                    recipientDetailRows
                        .padding(.top, 4)
                } label: {
                    Text(recipientSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var modeControl: some View {
        if availableModes.count > 1 {
            Menu {
                ForEach(availableModes, id: \.self) { mode in
                    Button {
                        onModeSelected(mode)
                    } label: {
                        SwiftUI.Label(mode.displayName, systemImage: mode.systemImage)
                    }
                }
            } label: {
                SwiftUI.Label(mode.displayName, systemImage: mode.systemImage)
                    .font(.caption.weight(.medium))
            }
        } else {
            SwiftUI.Label(mode.displayName, systemImage: mode.systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if onReply != nil || onForward != nil {
            HStack(spacing: 8) {
                if let onReply {
                    Button(action: onReply) {
                        Image(systemName: "arrow.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Reply")
                }

                if let onForward {
                    Button(action: onForward) {
                        Image(systemName: "arrow.turn.up.right")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Forward")
                }
            }
        }
    }

    @ViewBuilder
    private var recipientDetailRows: some View {
        let groups = recipientGroups
        if groups.isEmpty, let deliveredToAddress = nonEmptyText(message.deliveredToAddress) {
            recipientRow(label: "To", value: deliveredToAddress)
        } else {
            ForEach(groups, id: \.label) { group in
                recipientRow(label: group.label, value: group.people.joined(separator: ", "))
            }
        }
    }

    private func recipientRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            Text(value)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var subject: String {
        nonEmptyText(message.subject) ?? "No Subject"
    }

    private var senderLine: String {
        OriginalEmailMetadataFormatter.senderLine(
            senderName: message.senderName,
            senderEmail: message.senderEmail
        ) ?? PersonDisplayNameResolver.fallbackSenderName()
    }

    private var recipientSummary: String? {
        let groups = recipientGroups
        if groups.isEmpty {
            guard let deliveredToAddress = nonEmptyText(message.deliveredToAddress) else {
                return nil
            }
            return "To \(deliveredToAddress)"
        }

        let totalCount = groups.reduce(0) { $0 + $1.people.count }
        guard totalCount > 0 else {
            return nil
        }

        if totalCount == 1, let group = groups.first, let first = group.people.first {
            return "\(group.label) \(first)"
        }

        return "Recipients \(totalCount)"
    }

    private var recipientGroups: [RecipientGroup] {
        let participants = Array(message.participants ?? [])
            .filter { participant in
                switch participant.participantKind {
                case .to, .cc, .bcc:
                    return true
                case .from:
                    return false
                }
            }

        return [
            makeRecipientGroup(kind: .to, label: "To", participants: participants),
            makeRecipientGroup(kind: .cc, label: "Cc", participants: participants),
            makeRecipientGroup(kind: .bcc, label: "Bcc", participants: participants)
        ].compactMap { $0 }
    }

    private func makeRecipientGroup(
        kind: ParticipantKind,
        label: String,
        participants: [MessageParticipant]
    ) -> RecipientGroup? {
        let people = participants
            .filter { $0.participantKind == kind }
            .compactMap { participant -> String? in
                guard let person = participant.person else {
                    return nil
                }
                return Self.personLine(person)
            }
            .filter { !$0.isEmpty }
            .sorted()

        guard !people.isEmpty else {
            return nil
        }

        return RecipientGroup(label: label, people: people)
    }

    private static func personLine(_ person: Person) -> String {
        OriginalEmailMetadataFormatter.senderLine(
            senderName: person.displayName,
            senderEmail: person.email
        ) ?? person.email
    }

    private func nonEmptyText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private struct RecipientGroup {
        let label: String
        let people: [String]
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
