import Foundation
import Contacts
import UIKit

/// Owns the app's single deliberate Contacts permission request and reacts to
/// authorization changes from any source (this prompt, the contacts filter
/// toggle, the Settings app).
///
/// Resolution lookups never present the permission dialog themselves
/// (`ContactsResolver.ensureAuthorization` fails fast on `.notDetermined`), so
/// without this owner the prompt would never appear and rows settled on
/// header-derived names would never pick up address-book names or photos after
/// a grant.
@MainActor
final class ContactsAuthorizationCoordinator {
    static let shared = ContactsAuthorizationCoordinator()

    private let notificationCenter: NotificationCenter
    private let authorizationStatusProvider: () -> CNAuthorizationStatus
    private let requestAccess: () async -> CNAuthorizationStatus
    private let invalidateResolutionCaches: () async -> Void
    private let broadcastDisplayInfoChange: () -> Void

    private var lastObservedStatusRawValue: Int
    private var hasRequestedThisLaunch = false
    private var observationTokens: [NSObjectProtocol] = []

    /// All closure parameters are testing seams; production code uses `shared`.
    init(
        notificationCenter: NotificationCenter = .default,
        authorizationStatusProvider: @escaping () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        requestAccess: (() async -> CNAuthorizationStatus)? = nil,
        invalidateResolutionCaches: (() async -> Void)? = nil,
        broadcastDisplayInfoChange: (() -> Void)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.authorizationStatusProvider = authorizationStatusProvider
        self.requestAccess = requestAccess ?? {
            await ContactsResolver.shared.requestAccessIfNeeded()
        }
        self.invalidateResolutionCaches = invalidateResolutionCaches ?? {
            // Names, contact matches, and photos were all resolved (and
            // negative-cached — photos for 24h) without permission; drop them
            // so post-grant lookups reach the address book.
            await ContactsResolver.shared.invalidateAllCache()
            await ProfilePhotoResolver.shared.clearCache()
            await PersonCache.shared.clearCache()
        }
        self.broadcastDisplayInfoChange = broadcastDisplayInfoChange ?? {
            PersonDisplayInfoChangeNotification.postAllChanged()
        }
        self.lastObservedStatusRawValue = authorizationStatusProvider().rawValue
        startObservingStatusChanges()
    }

    deinit {
        for token in observationTokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// Presents the Contacts permission dialog once per install, right after
    /// the conversation list first appears. Safe to call on every appear: the
    /// per-launch guard and the `.notDetermined` check make repeats no-ops.
    func requestAccessOnFirstAuthenticatedLaunchIfNeeded() {
        guard !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true
        guard authorizationStatusProvider() == .notDetermined else { return }

        Task { [weak self] in
            guard let self else { return }
            _ = await self.requestAccess()
            await self.handlePotentialStatusChange()
        }
    }

    /// Re-checks authorization and, when it changed since last observed,
    /// invalidates permission-scoped caches and broadcasts a display-info
    /// change so settled rows re-resolve names and photos.
    func handlePotentialStatusChange() async {
        let status = authorizationStatusProvider()
        guard status.rawValue != lastObservedStatusRawValue else { return }
        lastObservedStatusRawValue = status.rawValue

        await invalidateResolutionCaches()
        broadcastDisplayInfoChange()
    }

    private func startObservingStatusChanges() {
        // Grants via other paths (contacts filter toggle, Settings) surface as
        // a store-change notification or on the next foreground.
        let names: [Notification.Name] = [
            .CNContactStoreDidChange,
            UIApplication.didBecomeActiveNotification
        ]
        for name in names {
            let token = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handlePotentialStatusChange()
                }
            }
            observationTokens.append(token)
        }
    }
}
