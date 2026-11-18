import Foundation
import CoreData

/// What a conversation row's trailing swipe offers, and the question its Report Spam asks, on
/// the iPhone's list and the Mac's sidebar alike (`View.conversationRowTrailingSwipeActions`,
/// `View.conversationSpamConfirmation`).
enum ConversationRowSwipePolicy {
    /// One button of the trailing swipe.
    enum TrailingAction: Hashable, CaseIterable {
        case archive
        case reportSpam

        var title: String {
            switch self {
            case .archive: return "Archive"
            // As the context menu and the chat's menu name it.
            case .reportSpam: return "Report Spam"
            }
        }

        var systemImage: String {
            switch self {
            case .archive: return "archivebox"
            case .reportSpam: return "exclamationmark.triangle"
            }
        }

        /// Archive stands for the row's removal. Report Spam does not: a destructive swipe button
        /// stands for the row's removal, and a list may animate the row away as the button is
        /// tapped, before the question it asks is answered. On the Mac the role reaches the
        /// table as `NSTableViewRowAction.Style.destructive`, which AppKit's header says does
        /// "a special animation when being deleted" (`ConversationRowTrailingSwipeActionsMacTests`
        /// reads the styles); on the iPhone it is reported of SwiftUI's lists, not measured here.
        var isDestructive: Bool {
            self == .archive
        }
    }

    /// The trailing swipe's buttons, the one at the row's edge first.
    ///
    /// The order is the behavior: SwiftUI performs a full swipe with the first button, so a
    /// full swipe archives and Report Spam is reached only by a partial swipe. Report Spam only
    /// asks (`SpamReportRequest`): it sits beside Archive, and nothing in the app takes it back
    /// (there is no Not Spam), so a tap that missed Archive by a few points would otherwise
    /// report the conversation for good.
    ///
    /// - Parameter isEnabled: False while the iPhone list selects, and while the row's own
    ///   report is running. Nothing is offered then, Report Spam included: left on its own it
    ///   would be the first button, and a full swipe would perform it.
    static func trailingActions(isEnabled: Bool) -> [TrailingAction] {
        isEnabled ? [.archive, .reportSpam] : []
    }

    /// A row's Report Spam waiting for its answer: the conversation, and the name the question
    /// gives it, read from the row when it was swiped.
    struct SpamReportRequest: Equatable {
        let conversationID: NSManagedObjectID
        /// Nil where the row has no stored name; the question then asks about "this conversation".
        let conversationName: String?

        /// - Parameter storedName: The conversation's stored title (`ConversationSnapshot
        ///   .displayNameHint`). Blank is no name.
        init(conversationID: NSManagedObjectID, storedName: String?) {
            self.conversationID = conversationID
            let trimmed = storedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.conversationName = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Longest name the question shows whole. A list's or a group's title can run to a line or
    /// more, and the question is about which conversation, not about its full title.
    static let questionNameLimit = 60

    /// The question's title, naming the conversation. Once the swipe has closed nothing else on
    /// screen says which row asked (on the iPad the question is a popover over the whole list),
    /// and a wrong row is exactly what the question is there to catch.
    static func questionTitle(for request: SpamReportRequest?) -> String {
        guard let name = request?.conversationName else {
            return "Report this conversation as spam?"
        }
        let shown = name.count > questionNameLimit
            ? String(name.prefix(questionNameLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : name
        return "Report \u{201C}\(shown)\u{201D} as spam?"
    }

    static let questionMessage = "Its messages move to Spam in Gmail, and the conversation leaves this list."

    /// The conversation an answered question reports, once the question is gone, and nil until
    /// then. SwiftUI does not promise which comes first, the answer's action or the question
    /// leaving, so both ask this and whichever comes second acts (as `FailedSendRecoveryPolicy
    /// .actionToRun` does for the send-recovery question).
    static func conversationToReport(answered: SpamReportRequest?, isQuestionPresented: Bool) -> NSManagedObjectID? {
        isQuestionPresented ? nil : answered?.conversationID
    }

    /// Whether the question is taken down, unanswered, because its row has left the list (a
    /// sync archived the conversation, a search or a filter hid it). Both lists act only on rows
    /// they show: answered after the row left, the iPhone would report a conversation that was
    /// archived meanwhile and the Mac would drop the answer without a word, so neither is asked.
    static func withdrawsQuestion(isQuestionPresented: Bool, conversationIsListed: Bool) -> Bool {
        isQuestionPresented && !conversationIsListed
    }
}
