import Foundation

/// A Set with a maximum size that automatically prunes oldest entries when full.
/// Uses insertion order tracking for FIFO eviction (oldest entries removed first).
///
/// Thread-safety: This struct is NOT thread-safe. For concurrent access, use within an actor
/// or wrap with appropriate synchronization.
///
/// Usage:
/// ```
/// var failedURLs = BoundedSet<String>(maxSize: 500)
/// failedURLs.insert("https://example.com/image.jpg")
/// if failedURLs.contains("https://example.com/image.jpg") { ... }
/// ```
struct BoundedSet<Element: Hashable>: Sendable where Element: Sendable {
    private var internalSet: Set<Element>
    private var insertionOrder: [Element]
    private let maxSize: Int
    private let prunePercentage: Double

    /// Creates a bounded set with specified maximum size
    /// - Parameters:
    ///   - maxSize: Maximum number of elements before pruning occurs
    ///   - prunePercentage: Percentage of oldest elements to remove when full (0.0-1.0, default 0.2)
    init(maxSize: Int, prunePercentage: Double = 0.2) {
        precondition(maxSize > 0, "maxSize must be positive")
        precondition(prunePercentage > 0 && prunePercentage <= 1.0, "prunePercentage must be between 0 and 1")

        self.maxSize = maxSize
        self.prunePercentage = prunePercentage
        self.internalSet = []
        self.insertionOrder = []
    }

    /// Returns true if the set contains the element
    func contains(_ element: Element) -> Bool {
        internalSet.contains(element)
    }

    /// Inserts an element into the set, pruning oldest entries if needed
    /// - Parameter element: The element to insert
    /// - Returns: True if the element was newly inserted, false if it already existed
    @discardableResult
    mutating func insert(_ element: Element) -> Bool {
        // If already present, don't update insertion order (keeps original timestamp)
        if internalSet.contains(element) {
            return false
        }

        // Prune if at capacity
        if internalSet.count >= maxSize {
            prune()
        }

        internalSet.insert(element)
        insertionOrder.append(element)
        return true
    }

    /// Removes an element from the set
    /// - Parameter element: The element to remove
    /// - Returns: The removed element, or nil if not found
    @discardableResult
    mutating func remove(_ element: Element) -> Element? {
        guard internalSet.remove(element) != nil else { return nil }
        insertionOrder.removeAll { $0 == element }
        return element
    }

    /// Removes all elements from the set
    mutating func removeAll() {
        internalSet.removeAll()
        insertionOrder.removeAll()
    }

    /// Number of elements in the set
    var count: Int {
        return internalSet.count
    }

    /// Whether the set is empty
    var isEmpty: Bool {
        return internalSet.isEmpty
    }

    /// Removes the oldest entries based on prunePercentage
    private mutating func prune() {
        let removeCount = Swift.max(1, Int(Double(maxSize) * prunePercentage))

        for _ in 0..<removeCount {
            guard !insertionOrder.isEmpty else { break }
            let oldest = insertionOrder.removeFirst()
            internalSet.remove(oldest)
        }
    }
}

// MARK: - Sequence Conformance

extension BoundedSet: Sequence {
    func makeIterator() -> Set<Element>.Iterator {
        internalSet.makeIterator()
    }
}
