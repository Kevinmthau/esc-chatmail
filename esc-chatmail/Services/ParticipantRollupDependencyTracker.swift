import Foundation
import Contacts

protocol ParticipantRollupDependencyTracking: AnyObject {
    func fingerprint(for emails: [String]) -> ParticipantRollupDependencyFingerprint
    func invalidate(email: String)
    func invalidateAll()
}

struct ParticipantRollupDependencyFingerprint: Equatable, Sendable {
    let globalGeneration: UInt64
    let emailGenerations: [String: UInt64]
    let contactsAuthorizationStatusRawValue: Int
}

final class ParticipantRollupDependencyTracker: ParticipantRollupDependencyTracking, @unchecked Sendable {
    static let shared = ParticipantRollupDependencyTracker()

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var nextGeneration: UInt64 = 1
    private var globalGeneration: UInt64 = 0
    private var emailGenerations: [String: UInt64] = [:]

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.contactsDidChangeObserver = notificationCenter.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateAll()
        }
    }

    deinit {
        if let contactsDidChangeObserver {
            notificationCenter.removeObserver(contactsDidChangeObserver)
        }
    }

    func fingerprint(for emails: [String]) -> ParticipantRollupDependencyFingerprint {
        let normalizedEmails = normalizedUniqueEmails(from: emails)
        let contactsAuthorizationStatusRawValue = CNContactStore.authorizationStatus(for: .contacts).rawValue

        lock.lock()
        defer { lock.unlock() }

        var versions: [String: UInt64] = [:]
        versions.reserveCapacity(normalizedEmails.count)

        for email in normalizedEmails {
            versions[email] = emailGenerations[email] ?? 0
        }

        return ParticipantRollupDependencyFingerprint(
            globalGeneration: globalGeneration,
            emailGenerations: versions,
            contactsAuthorizationStatusRawValue: contactsAuthorizationStatusRawValue
        )
    }

    func invalidate(email: String) {
        let normalizedEmail = EmailNormalizer.normalize(email)
        guard !normalizedEmail.isEmpty else {
            invalidateAll()
            return
        }

        lock.lock()
        emailGenerations[normalizedEmail] = nextGeneration
        nextGeneration &+= 1
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        globalGeneration = nextGeneration
        nextGeneration &+= 1
        emailGenerations.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func normalizedUniqueEmails(from emails: [String]) -> [String] {
        var seenEmails = Set<String>()
        var normalizedEmails: [String] = []

        for email in emails {
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  seenEmails.insert(normalizedEmail).inserted else {
                continue
            }

            normalizedEmails.append(normalizedEmail)
        }

        return normalizedEmails.sorted()
    }
}
