import Foundation

/// UI-facing wrapper around ParallelMessageFetcher with adaptive optimization
/// Automatically adjusts fetch configuration based on performance metrics
final class AdaptiveMessageFetcher: ObservableObject {
    @Published var isOptimizing = false
    @Published var currentConfiguration: FetchConfiguration = .default

    private let fetcher = ParallelMessageFetcher.shared
    private var optimizationTimer: Timer?

    init() {
        startOptimization()
    }

    private func startOptimization() {
        optimizationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { [weak self] in
                await self?.optimize()
            }
        }
    }

    private func optimize() async {
        await MainActor.run {
            isOptimizing = true
        }

        await fetcher.optimizeConfiguration()

        await MainActor.run {
            isOptimizing = false
        }
    }

    /// Fetches messages with context-aware priority
    func fetchWithPriority(messageIds: [String], conversationId: String) async -> [GmailMessage] {
        let priority = determinePriority(for: conversationId)

        do {
            return try await fetcher.fetchMessages(messageIds, priority: priority)
        } catch {
            Log.error("Failed to fetch messages", category: .sync, error: error)
            return []
        }
    }

    private func determinePriority(for conversationId: String) -> FetchPriority {
        // Logic to determine priority based on:
        // - Is this the currently viewed conversation?
        // - Is it marked as important?
        // - Is it from a VIP contact?
        // - Is it unread?

        // For now, return normal priority
        return .normal
    }

    deinit {
        optimizationTimer?.invalidate()
    }
}
