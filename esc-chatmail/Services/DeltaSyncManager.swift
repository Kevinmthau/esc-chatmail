import Foundation
import CoreData
import Combine

// MARK: - Delta Sync Token
struct DeltaSyncToken: Codable {
    let historyId: String
    let syncToken: String?
    let lastSyncDate: Date
    let messageCount: Int
    let checksum: String?
}

// MARK: - Delta Sync Strategy
enum DeltaSyncStrategy {
    case full
    case incremental(since: Date)
    case token(DeltaSyncToken)
    case changeDetection
}

// MARK: - Delta Sync Manager
@MainActor
final class DeltaSyncManager: ObservableObject {
    static let shared = DeltaSyncManager()

    @Published var syncStrategy: DeltaSyncStrategy = .full
    @Published var pendingChanges: Int = 0
    @Published var lastSuccessfulSync: Date?

    private let keychainService = KeychainService.shared
    private let coreDataStack = CoreDataStack.shared
    private var syncTokenKey = "com.esc.inboxchat.deltaSyncToken"
    private var cancellables = Set<AnyCancellable>()

    // Change tracking
    private var localChangeSet = Set<String>()
    private var remoteChangeSet = Set<String>()
    private let changeQueue = DispatchQueue(label: "com.esc.deltasync.changes", attributes: .concurrent)

    private init() {
        loadSyncToken()
        setupChangeTracking()
    }

    // MARK: - Token Management

    func saveSyncToken(_ token: DeltaSyncToken) {
        do {
            try keychainService.saveCodable(token, for: syncTokenKey)
            lastSuccessfulSync = token.lastSyncDate
        } catch {
            print("Failed to save sync token: \(error)")
        }
    }

    func loadSyncToken() {
        do {
            let token: DeltaSyncToken = try keychainService.loadCodable(DeltaSyncToken.self, for: syncTokenKey)
            syncStrategy = .token(token)
            lastSuccessfulSync = token.lastSyncDate
        } catch {
            print("No valid sync token found, will perform full sync")
            syncStrategy = .full
        }
    }

    func clearSyncToken() {
        try? keychainService.delete(for: syncTokenKey)
        syncStrategy = .full
        lastSuccessfulSync = nil
    }

    // MARK: - Change Detection

    private func setupChangeTracking() {
        // Monitor Core Data changes
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: coreDataStack.viewContext)
            .sink { [weak self] notification in
                self?.handleContextChanges(notification)
            }
            .store(in: &cancellables)
    }

    private func handleContextChanges(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        Task { @MainActor in
            // Track inserted objects
            if let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> {
                for object in inserted {
                    if let message = object as? Message {
                        self.localChangeSet.insert(message.id)
                    }
                }
            }

            // Track updated objects
            if let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
                for object in updated {
                    if let message = object as? Message {
                        self.localChangeSet.insert(message.id)
                    }
                }
            }

            // Track deleted objects
            if let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> {
                for object in deleted {
                    if let message = object as? Message {
                        self.localChangeSet.remove(message.id)
                    }
                }
            }

            self.pendingChanges = self.localChangeSet.count
        }
    }

    // MARK: - Delta Sync Operations

    func performDeltaSync(using apiClient: GmailAPIClient) async throws -> DeltaSyncResult {
        switch syncStrategy {
        case .full:
            return try await performFullSync(using: apiClient)
        case .incremental(let since):
            return try await performIncrementalSync(since: since, using: apiClient)
        case .token(let token):
            return try await performTokenBasedSync(token: token, using: apiClient)
        case .changeDetection:
            return try await performChangeDetectionSync(using: apiClient)
        }
    }

    private func performFullSync(using apiClient: GmailAPIClient) async throws -> DeltaSyncResult {
        print("Performing full sync...")

        let startTime = Date()
        var messageIds: [String] = []
        var pageToken: String? = nil

        repeat {
            let response = try await apiClient.listMessages(
                pageToken: pageToken,
                maxResults: 500,
                query: "after:\(Int(Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970))"
            )

            if let messages = response.messages {
                messageIds.append(contentsOf: messages.map { $0.id })
            }
            pageToken = response.nextPageToken
        } while pageToken != nil

        // Generate new sync token
        let newToken = DeltaSyncToken(
            historyId: "", // Will be updated after sync
            syncToken: UUID().uuidString,
            lastSyncDate: Date(),
            messageCount: messageIds.count,
            checksum: generateChecksum(for: messageIds)
        )

        saveSyncToken(newToken)

        return DeltaSyncResult(
            strategy: .full,
            messagesAdded: messageIds.count,
            messagesUpdated: 0,
            messagesDeleted: 0,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    private func performIncrementalSync(since: Date, using apiClient: GmailAPIClient) async throws -> DeltaSyncResult {
        print("Performing incremental sync since \(since)...")

        let startTime = Date()
        let epochSeconds = Int(since.timeIntervalSince1970)
        let query = "after:\(epochSeconds)"

        var addedCount = 0
        var updatedCount = 0
        var pageToken: String? = nil

        repeat {
            let response = try await apiClient.listMessages(
                pageToken: pageToken,
                maxResults: 100,
                query: query
            )

            if let messages = response.messages {
                for message in messages {
                    if localChangeSet.contains(message.id) {
                        updatedCount += 1
                    } else {
                        addedCount += 1
                    }
                    remoteChangeSet.insert(message.id)
                }
            }
            pageToken = response.nextPageToken
        } while pageToken != nil

        // Detect deletions
        let deletedCount = localChangeSet.subtracting(remoteChangeSet).count

        return DeltaSyncResult(
            strategy: .incremental(since: since),
            messagesAdded: addedCount,
            messagesUpdated: updatedCount,
            messagesDeleted: deletedCount,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    private func performTokenBasedSync(token: DeltaSyncToken, using apiClient: GmailAPIClient) async throws -> DeltaSyncResult {
        print("Performing token-based sync with token: \(token.syncToken ?? "none")")

        let startTime = Date()

        // Use Gmail history API with the stored historyId
        guard !token.historyId.isEmpty else {
            // Fall back to incremental sync
            return try await performIncrementalSync(since: token.lastSyncDate, using: apiClient)
        }

        var addedCount = 0
        var updatedCount = 0
        var deletedCount = 0
        var pageToken: String? = nil
        var latestHistoryId = token.historyId

        repeat {
            let response = try await apiClient.listHistory(
                startHistoryId: token.historyId,
                pageToken: pageToken
            )

            if let history = response.history {
                for record in history {
                    addedCount += record.messagesAdded?.count ?? 0
                    updatedCount += record.labelsAdded?.count ?? 0
                    deletedCount += record.messagesDeleted?.count ?? 0
                }
            }

            if let newHistoryId = response.historyId {
                latestHistoryId = newHistoryId
            }

            pageToken = response.nextPageToken
        } while pageToken != nil

        // Update token with new historyId
        let newToken = DeltaSyncToken(
            historyId: latestHistoryId,
            syncToken: UUID().uuidString,
            lastSyncDate: Date(),
            messageCount: token.messageCount + addedCount - deletedCount,
            checksum: nil
        )

        saveSyncToken(newToken)

        return DeltaSyncResult(
            strategy: .token(token),
            messagesAdded: addedCount,
            messagesUpdated: updatedCount,
            messagesDeleted: deletedCount,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    private func performChangeDetectionSync(using apiClient: GmailAPIClient) async throws -> DeltaSyncResult {
        print("Performing change detection sync...")

        let startTime = Date()

        // Get message IDs from the last 7 days
        let query = "after:\(Int(Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970))"
        var remoteIds = Set<String>()
        var pageToken: String? = nil

        repeat {
            let response = try await apiClient.listMessages(
                pageToken: pageToken,
                maxResults: 500,
                query: query
            )

            if let messages = response.messages {
                messages.forEach { remoteIds.insert($0.id) }
            }
            pageToken = response.nextPageToken
        } while pageToken != nil

        // Compare with local state
        let context = coreDataStack.newBackgroundContext()
        let localIds = try await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(
                format: "internalDate >= %@",
                Date().addingTimeInterval(-7 * 24 * 3600) as NSDate
            )
            request.propertiesToFetch = ["id"]
            request.resultType = .dictionaryResultType

            let results = try context.fetch(request) as? [[String: Any]] ?? []
            return Set(results.compactMap { $0["id"] as? String })
        }

        let toAdd = remoteIds.subtracting(localIds)
        let toDelete = localIds.subtracting(remoteIds)

        return DeltaSyncResult(
            strategy: .changeDetection,
            messagesAdded: toAdd.count,
            messagesUpdated: 0,
            messagesDeleted: toDelete.count,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Utilities

    private func generateChecksum(for messageIds: [String]) -> String {
        let sortedIds = messageIds.sorted().joined()
        return String(sortedIds.hashValue)
    }

    func shouldPerformFullSync() -> Bool {
        guard case .token(let token) = syncStrategy else {
            return true
        }

        // Perform full sync if:
        // 1. Last sync was more than 24 hours ago
        // 2. We have too many pending local changes
        // 3. Checksum mismatch detected

        let hoursSinceSync = Date().timeIntervalSince(token.lastSyncDate) / 3600
        return hoursSinceSync > 24 || pendingChanges > 100
    }

    func optimizeSyncStrategy() {
        if shouldPerformFullSync() {
            syncStrategy = .full
        } else if let lastSync = lastSuccessfulSync {
            let minutesSinceSync = Date().timeIntervalSince(lastSync) / 60

            if minutesSinceSync < 5 {
                // Use change detection for very recent syncs
                syncStrategy = .changeDetection
            } else if minutesSinceSync < 60 {
                // Use incremental for recent syncs
                syncStrategy = .incremental(since: lastSync)
            } else {
                // Use token-based for older syncs
                if case .token(let token) = syncStrategy {
                    syncStrategy = .token(token)
                } else {
                    syncStrategy = .incremental(since: lastSync)
                }
            }
        }
    }
}

// MARK: - Delta Sync Result
struct DeltaSyncResult {
    let strategy: DeltaSyncStrategy
    let messagesAdded: Int
    let messagesUpdated: Int
    let messagesDeleted: Int
    let duration: TimeInterval

    var totalChanges: Int {
        messagesAdded + messagesUpdated + messagesDeleted
    }

    var summary: String {
        "Sync completed: +\(messagesAdded) new, ~\(messagesUpdated) updated, -\(messagesDeleted) deleted in \(String(format: "%.2f", duration))s"
    }
}