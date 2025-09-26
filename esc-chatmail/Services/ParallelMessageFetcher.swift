import Foundation
import CoreData

// MARK: - Fetch Configuration
struct FetchConfiguration {
    let maxConcurrency: Int
    let batchSize: Int
    let timeout: TimeInterval
    let retryAttempts: Int
    let priorityBoost: Bool

    static let `default` = FetchConfiguration(
        maxConcurrency: 4,
        batchSize: 50,
        timeout: 30,
        retryAttempts: 3,
        priorityBoost: false
    )

    static let aggressive = FetchConfiguration(
        maxConcurrency: 8,
        batchSize: 100,
        timeout: 45,
        retryAttempts: 2,
        priorityBoost: true
    )

    static let conservative = FetchConfiguration(
        maxConcurrency: 2,
        batchSize: 25,
        timeout: 60,
        retryAttempts: 5,
        priorityBoost: false
    )
}

// MARK: - Fetch Priority
enum FetchPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    static func < (lhs: FetchPriority, rhs: FetchPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Fetch Task
struct FetchTask: Identifiable {
    let id = UUID()
    let messageIds: [String]
    let priority: FetchPriority
    let completion: ([GmailMessage]) -> Void
}

// MARK: - Parallel Message Fetcher
actor ParallelMessageFetcher {
    static let shared = ParallelMessageFetcher()

    private var activeTasks: [UUID: Task<Void, Error>] = [:]
    private var taskQueue: [FetchTask] = []
    private var configuration: FetchConfiguration

    // Metrics
    private var totalFetched = 0
    private var totalErrors = 0
    private var averageFetchTime: TimeInterval = 0
    private var fetchTimes: [TimeInterval] = []

    private init(configuration: FetchConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public Methods

    func updateConfiguration(_ config: FetchConfiguration) {
        self.configuration = config
    }

    func fetchMessages(_ messageIds: [String], priority: FetchPriority = .normal) async throws -> [GmailMessage] {
        return try await withCheckedThrowingContinuation { continuation in
            let task = FetchTask(
                messageIds: messageIds,
                priority: priority
            ) { messages in
                continuation.resume(returning: messages)
            }

            Task {
                enqueueTask(task)
                await processTasks()
            }
        }
    }

    func fetchMessagesBatched(_ messageIds: [String], onBatch: @escaping ([GmailMessage]) -> Void) async {
        let batches = messageIds.chunked(into: configuration.batchSize)

        await withTaskGroup(of: [GmailMessage].self) { group in
            for (index, batch) in batches.enumerated() {
                let priority: FetchPriority = index == 0 ? .high : .normal

                group.addTask { [weak self] in
                    guard let self = self else { return [] }
                    do {
                        return try await self.fetchBatch(batch, priority: priority)
                    } catch {
                        print("Batch \(index) failed: \(error)")
                        return []
                    }
                }
            }

            for await messages in group {
                if !messages.isEmpty {
                    onBatch(messages)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func enqueueTask(_ task: FetchTask) {
        // Insert task based on priority
        if let insertIndex = taskQueue.firstIndex(where: { $0.priority < task.priority }) {
            taskQueue.insert(task, at: insertIndex)
        } else {
            taskQueue.append(task)
        }
    }

    private func processTasks() async {
        while !taskQueue.isEmpty && activeTasks.count < configuration.maxConcurrency {
            let task = taskQueue.removeFirst()
            await executeTask(task)
        }
    }

    private func executeTask(_ fetchTask: FetchTask) async {
        let task = Task<Void, Error> {
            let startTime = Date()
            var messages: [GmailMessage] = []

            do {
                messages = try await fetchBatch(fetchTask.messageIds, priority: fetchTask.priority)
                recordFetchTime(Date().timeIntervalSince(startTime))
                incrementTotalFetched(by: messages.count)
            } catch {
                incrementErrors()
                print("Failed to fetch batch: \(error)")
            }

            fetchTask.completion(messages)
        }

        activeTasks[fetchTask.id] = task

        // Clean up after completion
        _ = await task.result
        activeTasks.removeValue(forKey: fetchTask.id)

        // Process next tasks
        await processTasks()
    }

    private func fetchBatch(_ messageIds: [String], priority: FetchPriority) async throws -> [GmailMessage] {
        let timeout = priority == .urgent ? configuration.timeout / 2 : configuration.timeout

        return try await withThrowingTaskGroup(of: GmailMessage?.self) { group in
            for messageId in messageIds {
                group.addTask { [weak self] in
                    guard let self = self else { return nil }

                    return try await self.fetchSingleMessage(
                        messageId,
                        timeout: timeout,
                        retryAttempts: priority == .urgent ? 1 : self.configuration.retryAttempts
                    )
                }
            }

            var messages: [GmailMessage] = []
            for try await message in group {
                if let message = message {
                    messages.append(message)
                }
            }
            return messages
        }
    }

    private func fetchSingleMessage(_ messageId: String, timeout: TimeInterval, retryAttempts: Int) async throws -> GmailMessage? {
        var lastError: Error?

        for attempt in 0..<retryAttempts {
            do {
                // Add timeout
                let task = Task { @MainActor in
                    try await GmailAPIClient.shared.getMessage(id: messageId)
                }

                let timeoutTask = Task {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    task.cancel()
                    throw NSError(domain: "ParallelFetcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout"])
                }

                let message = try await task.value
                timeoutTask.cancel()
                return message

            } catch {
                lastError = error
                if attempt < retryAttempts - 1 {
                    // Exponential backoff
                    let delay = Double(attempt + 1) * 0.5
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? NSError(domain: "ParallelFetcher", code: -2)
    }

    // MARK: - Metrics

    private func recordFetchTime(_ time: TimeInterval) {
        fetchTimes.append(time)
        if fetchTimes.count > 100 {
            fetchTimes.removeFirst()
        }
        averageFetchTime = fetchTimes.reduce(0, +) / Double(fetchTimes.count)
    }

    private func incrementTotalFetched(by count: Int) {
        totalFetched += count
    }

    private func incrementErrors() {
        totalErrors += 1
    }

    func getMetrics() -> FetchMetrics {
        FetchMetrics(
            totalFetched: totalFetched,
            totalErrors: totalErrors,
            averageFetchTime: averageFetchTime,
            activeTaskCount: activeTasks.count,
            queuedTaskCount: taskQueue.count
        )
    }

    func optimizeConfiguration() {
        // Dynamically adjust configuration based on metrics
        let errorRate = Double(totalErrors) / Double(max(1, totalFetched))

        if errorRate > 0.1 {
            // High error rate, be more conservative
            configuration = FetchConfiguration(
                maxConcurrency: max(1, configuration.maxConcurrency - 1),
                batchSize: max(10, configuration.batchSize - 10),
                timeout: min(120, configuration.timeout + 10),
                retryAttempts: min(5, configuration.retryAttempts + 1),
                priorityBoost: false
            )
        } else if errorRate < 0.02 && averageFetchTime < 5.0 {
            // Low error rate and fast fetches, be more aggressive
            configuration = FetchConfiguration(
                maxConcurrency: min(10, configuration.maxConcurrency + 1),
                batchSize: min(100, configuration.batchSize + 10),
                timeout: max(20, configuration.timeout - 5),
                retryAttempts: max(1, configuration.retryAttempts - 1),
                priorityBoost: true
            )
        }
    }
}

// MARK: - Fetch Metrics
struct FetchMetrics {
    let totalFetched: Int
    let totalErrors: Int
    let averageFetchTime: TimeInterval
    let activeTaskCount: Int
    let queuedTaskCount: Int

    var errorRate: Double {
        guard totalFetched > 0 else { return 0 }
        return Double(totalErrors) / Double(totalFetched)
    }

    var throughput: Double {
        guard averageFetchTime > 0 else { return 0 }
        return 1.0 / averageFetchTime
    }
}

// MARK: - Adaptive Fetcher
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

    func fetchWithPriority(messageIds: [String], conversationId: String) async -> [GmailMessage] {
        // Determine priority based on context
        let priority: FetchPriority = determingPriority(for: conversationId)

        do {
            return try await fetcher.fetchMessages(messageIds, priority: priority)
        } catch {
            print("Failed to fetch messages: \(error)")
            return []
        }
    }

    private func determingPriority(for conversationId: String) -> FetchPriority {
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