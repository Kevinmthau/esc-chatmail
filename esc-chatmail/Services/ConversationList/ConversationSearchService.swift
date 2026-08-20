import Foundation
import Combine

/// Service for handling search input with debouncing in the conversation list
@MainActor
final class ConversationSearchService: ObservableObject {
    // MARK: - Published State

    @Published var searchText = "" {
        didSet {
            debounceSearch()
        }
    }
    @Published private(set) var debouncedSearchText = "" {
        didSet {
            guard debouncedSearchText != oldValue else { return }
            onDebouncedSearchTextChange?()
        }
    }

    // MARK: - Private State

    private var searchDebounceTask: Task<Void, Never>?
    private let debounceInterval: UInt64
    private let clock: any SyncClock
    var onDebouncedSearchTextChange: (() -> Void)?

    // MARK: - Initialization

    /// Creates a new search service
    /// - Parameters:
    ///   - debounceInterval: Debounce interval in nanoseconds (default: 150ms)
    ///   - clock: Sleep source for the debounce delay. Inject `FakeSyncClock`
    ///     in tests to drive the debounce deterministically.
    init(debounceInterval: UInt64 = 150_000_000, clock: any SyncClock = SystemSyncClock()) {
        self.debounceInterval = debounceInterval
        self.clock = clock
    }

    // MARK: - Public API

    /// Called when the view disappears to clean up resources
    func cleanup() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    // MARK: - Private Methods

    private func debounceSearch() {
        searchDebounceTask?.cancel()

        if searchText.isEmpty {
            debouncedSearchText = ""
            return
        }

        let pendingQuery = searchText
        let clock = clock
        let debounceInterval = debounceInterval

        searchDebounceTask = Task { [weak self] in
            do {
                try await clock.sleep(nanoseconds: debounceInterval)
            } catch {
                // Cancellation must bail explicitly here: a cancelled sleep
                // that fell through would skip the debounce delay and publish
                // a superseded query anyway (#119 lineage).
                return
            }

            guard let self, self.searchText == pendingQuery else { return }
            self.debouncedSearchText = pendingQuery
        }
    }
}
