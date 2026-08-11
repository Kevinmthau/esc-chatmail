import Foundation
import CoreData

/// Extension containing Core Data persistence logic for ContactsResolver.
///
/// Handles updating Person entities with contact information from the address book.
extension ContactsResolver {

    /// Updates a Person entity with contact information.
    /// Saves avatar to file storage and updates Core Data.
    /// - Parameters:
    ///   - email: The email address of the person
    ///   - match: The contact match containing name and avatar data
    func updatePerson(
        email: String,
        match: ContactMatch,
        accountGeneration: ParticipantCacheAccountGenerationToken
    ) async {
        guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return }
        let displayName = match.displayName
        let imageData = match.imageData

        // Save avatar to file storage outside of context.perform (async operation)
        var avatarFileURL: String?
        if let imageData = imageData {
            avatarFileURL = await saveAvatar(email, imageData)
        }
        guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return }

        let context = coreDataStack.newBackgroundContext()

        let didChange = await context.perform {
            accountGeneration.withActiveGeneration {
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email == %@", email)

                do {
                    if let person = try context.fetch(request).first {
                        var hasChanges = false

                        // Address book name always takes precedence over email header name
                        if let displayName = displayName, !displayName.isEmpty,
                           person.displayName != displayName {
                            person.displayName = displayName
                            hasChanges = true
                        }

                        if person.avatarURL == nil, let fileURL = avatarFileURL {
                            person.avatarURL = fileURL
                            hasChanges = true
                        }

                        // Only save if there are actual changes
                        if hasChanges && context.hasChanges {
                            try context.save()
                        }
                        return hasChanges
                    }
                } catch {
                    Log.error("Failed to update Person", category: .general, error: error)
                }

                return false
            } ?? false
        }

        if didChange, isCurrentAccountGeneration(accountGeneration) {
            await PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPost(emails: [email])
        }
    }
}
