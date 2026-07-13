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
    var onDebouncedSearchTextChange: (() -> Void)?

    // MARK: - Initialization

    /// Creates a new search service
    /// - Parameter debounceInterval: Debounce interval in nanoseconds (default: 150ms)
    init(debounceInterval: UInt64 = 150_000_000) {
        self.debounceInterval = debounceInterval
    }

    // MARK: - Public API

    /// Clears the search text
    func clearSearch() {
        searchText = ""
        debouncedSearchText = ""
        searchDebounceTask?.cancel()
    }

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
        let debounceInterval = debounceInterval

        searchDebounceTask = Task.detached { [weak self] in
            guard await Task.sleepUnlessCancelled(nanoseconds: debounceInterval) else { return }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.searchText == pendingQuery else { return }
                self.debouncedSearchText = pendingQuery
            }
        }
    }
}
