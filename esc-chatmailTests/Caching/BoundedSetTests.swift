import XCTest
@testable import esc_chatmail

final class BoundedSetTests: XCTestCase {

    // MARK: - Basic Operations

    func testInsertAndContains() {
        var set = BoundedSet<String>(maxSize: 10)

        XCTAssertTrue(set.insert("a"))
        XCTAssertTrue(set.contains("a"))
        XCTAssertFalse(set.contains("b"))
    }

    func testInsertDuplicateReturnsFalse() {
        var set = BoundedSet<String>(maxSize: 10)

        XCTAssertTrue(set.insert("a"))
        XCTAssertFalse(set.insert("a"))
        XCTAssertEqual(set.count, 1)
    }

    func testRemove() {
        var set = BoundedSet<String>(maxSize: 10)

        set.insert("a")
        set.insert("b")

        XCTAssertEqual(set.remove("a"), "a")
        XCTAssertFalse(set.contains("a"))
        XCTAssertTrue(set.contains("b"))
        XCTAssertEqual(set.count, 1)
    }

    func testRemoveNonexistent() {
        var set = BoundedSet<String>(maxSize: 10)

        set.insert("a")
        XCTAssertNil(set.remove("b"))
        XCTAssertEqual(set.count, 1)
    }

    func testRemoveAll() {
        var set = BoundedSet<String>(maxSize: 10)

        set.insert("a")
        set.insert("b")
        set.insert("c")

        set.removeAll()

        XCTAssertTrue(set.isEmpty)
        XCTAssertEqual(set.count, 0)
    }

    // MARK: - Pruning Behavior

    func testPrunesOldestWhenFull() {
        var set = BoundedSet<String>(maxSize: 5, prunePercentage: 0.2)

        // Insert 5 elements (at capacity)
        set.insert("a")
        set.insert("b")
        set.insert("c")
        set.insert("d")
        set.insert("e")

        XCTAssertEqual(set.count, 5)

        // Insert 6th element - should prune oldest (20% = 1 element)
        set.insert("f")

        XCTAssertEqual(set.count, 5)
        XCTAssertFalse(set.contains("a")) // "a" was oldest, should be removed
        XCTAssertTrue(set.contains("f"))  // "f" should be present
    }

    func testPrunesCorrectPercentage() {
        var set = BoundedSet<String>(maxSize: 10, prunePercentage: 0.3)

        // Insert 10 elements
        for i in 0..<10 {
            set.insert("item\(i)")
        }

        XCTAssertEqual(set.count, 10)

        // Insert 11th element - should prune 30% = 3 elements
        set.insert("new")

        XCTAssertEqual(set.count, 8) // 10 - 3 + 1 = 8
        XCTAssertFalse(set.contains("item0"))
        XCTAssertFalse(set.contains("item1"))
        XCTAssertFalse(set.contains("item2"))
        XCTAssertTrue(set.contains("item3"))
        XCTAssertTrue(set.contains("new"))
    }

    func testMinimumPruneIsOne() {
        var set = BoundedSet<String>(maxSize: 3, prunePercentage: 0.1)

        // 10% of 3 = 0.3, but should prune at least 1
        set.insert("a")
        set.insert("b")
        set.insert("c")
        set.insert("d")

        XCTAssertEqual(set.count, 3)
        XCTAssertFalse(set.contains("a"))
    }

    // MARK: - Count and Empty

    func testCountAndIsEmpty() {
        var set = BoundedSet<String>(maxSize: 10)

        XCTAssertTrue(set.isEmpty)
        XCTAssertEqual(set.count, 0)

        set.insert("a")

        XCTAssertFalse(set.isEmpty)
        XCTAssertEqual(set.count, 1)

        set.insert("b")
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Sequence Conformance

    func testIteration() {
        var set = BoundedSet<Int>(maxSize: 10)

        set.insert(1)
        set.insert(2)
        set.insert(3)

        let collected = Set(set)
        XCTAssertEqual(collected, [1, 2, 3])
    }

    // MARK: - Integer Keys

    func testWithIntegerKeys() {
        var set = BoundedSet<Int>(maxSize: 5)

        set.insert(100)
        set.insert(200)
        set.insert(300)

        XCTAssertTrue(set.contains(100))
        XCTAssertTrue(set.contains(200))
        XCTAssertTrue(set.contains(300))
        XCTAssertFalse(set.contains(400))
    }
}
