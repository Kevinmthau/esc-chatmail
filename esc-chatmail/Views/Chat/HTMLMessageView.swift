import SwiftUI
import UIKit

// MARK: - Full HTML Message View
private enum OriginalEmailLoadedContent {
    case html(String)
    case plainText(String)
}

private enum OriginalEmailLoadState {
    case loading
    case recovering
    case loaded(OriginalEmailLoadedContent)
    case unavailable

    var hasLoadedContent: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }
}

struct OriginalEmailLoadIdentity: Equatable {
    let baseLoadKey: String

    static func make(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        subject: String?,
        senderEmail: String?
    ) -> OriginalEmailLoadIdentity {
        let baseLoadKey = [
            messageId,
            bodyStorageURI ?? "",
            "\(bodyText?.hashValue ?? 0)",
            "\(subject?.hashValue ?? 0)",
            "\(senderEmail?.hashValue ?? 0)"
        ].joined(separator: "|")

        return OriginalEmailLoadIdentity(baseLoadKey: baseLoadKey)
    }
}

struct HTMLMessageView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: OriginalEmailLoadState = .loading
    @State private var activeBaseLoadKey: String?
    @State private var activeLoadTaskKey: String?
    @State private var activeHTMLSourceSignature: String?
    @State private var reloadGeneration = 0

    private let originalEmailSourceLoader = OriginalEmailSourceLoader.shared
    private var loadIdentity: OriginalEmailLoadIdentity {
        OriginalEmailLoadIdentity.make(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            subject: message.subject,
            senderEmail: message.senderEmail
        )
    }
    private var baseLoadKey: String {
        loadIdentity.baseLoadKey
    }
    private var loadKey: String {
        "\(baseLoadKey)|reload:\(reloadGeneration)"
    }

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
            reloadIfRemoteImageFallbackWarmed(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: HTMLContentLoader.contentSourceDidChangeNotification)) { notification in
            reloadIfContentSourceChanged(notification)
        }
        .task(id: loadKey) {
            await loadHTMLContent()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .recovering:
            ProgressView("Recovering original email...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let loadedContent):
            switch loadedContent {
            case .html(let html):
                HTMLWebView(
                    htmlContent: html,
                    isDarkMode: false,
                    message: message
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .plainText(let text):
                OriginalEmailReadableView(message: message, text: text)
            }
        case .unavailable:
            ContentUnavailableView(
                "No Content",
                systemImage: "doc.text",
                description: Text("The original email content is not available")
            )
        }
    }

    private func loadHTMLContent() async {
        let taskLoadIdentity = loadIdentity
        let taskBaseLoadKey = taskLoadIdentity.baseLoadKey
        let taskLoadKey = "\(taskBaseLoadKey)|reload:\(reloadGeneration)"

        await MainActor.run {
            let shouldReset = activeBaseLoadKey != taskBaseLoadKey
            activeBaseLoadKey = taskBaseLoadKey
            activeLoadTaskKey = taskLoadKey
            if shouldReset {
                activeHTMLSourceSignature = nil
            }

            if shouldReset || !loadState.hasLoadedContent {
                loadState = .loading
            }
        }

        let recoveringTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard activeLoadTaskKey == taskLoadKey else {
                    return
                }
                if case .loading = loadState {
                    loadState = .recovering
                }
            }
        }
        defer { recoveringTask.cancel() }

        Log.diagnostic(.htmlPreview, level: .info, "HTMLMessageView loading message \(message.id)", category: .ui)
        let source = await originalEmailSourceLoader.loadOriginalEmailSourceToCompletion(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject,
            isDarkMode: false
        )

        guard !Task.isCancelled else {
            return
        }

        // If we loaded HTML from the per-message file location (or recovered/saved it there),
        // ensure Core Data points at the canonical file URL so the rest of the UI can treat it as
        // having a stable HTML source.
        if source?.shouldPointBodyStorageURIAtMessageFile == true,
           let context = message.managedObjectContext {
            let messageId = message.id
            Task {
                await context.perform {
                    guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                        return
                    }
                    let messagesDirectory = documentsPath.appendingPathComponent("Messages")
                    let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
                    message.bodyStorageURI = fileURL.absoluteString
                    context.saveOrLog(operation: "update message body storage URI")
                }
            }
        }

        await MainActor.run {
            guard activeLoadTaskKey == taskLoadKey else {
                return
            }

            activeHTMLSourceSignature = source?.sourceSignature

            switch source?.presentation {
            case .html:
                if let html = source?.html {
                    loadState = .loaded(.html(html))
                } else {
                    loadState = .unavailable
                }
            case .nativePlainText:
                if let plainText = source?.plainText {
                    loadState = .loaded(.plainText(plainText))
                } else {
                    loadState = .unavailable
                }
            case nil:
                loadState = .unavailable
            }
        }

        if let source {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "HTMLMessageView loaded message \(message.id) sourceKind=\(source.sourceKind.rawValue) sourceLocation=\(source.sourceLocation.rawValue) presentation=\(source.presentation.rawValue) hasHTML=\(source.html != nil)",
                category: .ui
            )
        }
    }

    private func reloadIfRemoteImageFallbackWarmed(_ notification: Notification) {
        guard let warmedMessageId = notification.userInfo?[HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey] as? String,
              warmedMessageId == message.id else {
            return
        }

        reloadGeneration &+= 1
    }

    private func reloadIfContentSourceChanged(_ notification: Notification) {
        guard let changedMessageId = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String,
              changedMessageId == message.id else {
            return
        }

        let changedSourceSignature = notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey] as? String
        if let changedSourceSignature,
           changedSourceSignature == activeHTMLSourceSignature {
            return
        }

        reloadGeneration &+= 1
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
