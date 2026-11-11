import CoreData

extension ConversationReference {
    /// The conversation a just-sent message went to, if a list can open it now: its row has
    /// reached `context` and it is not archived.
    ///
    /// Nil is not final. The optimistic conversation may not be in this context yet when the
    /// send reports it, so the caller keeps the reference and asks again once the compose sheet
    /// has dismissed (`ConversationListView`, `MacMailboxView`).
    @MainActor
    func openableConversation(in context: NSManagedObjectContext) -> Conversation? {
        guard let objectID = resolveObjectID(in: context),
              let conversation = try? context.existingObject(with: objectID) as? Conversation,
              conversation.archivedAt == nil else {
            return nil
        }
        return conversation
    }
}
