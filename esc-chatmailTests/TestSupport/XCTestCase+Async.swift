import XCTest

extension XCTestCase {

    /// Waits for an async operation to complete within a timeout.
    /// - Parameters:
    ///   - timeout: Maximum time to wait (default: 5 seconds)
    ///   - description: Description for the expectation
    ///   - operation: The async operation to execute
    func waitForAsync(
        timeout: TimeInterval = 5.0,
        description: String = "Async operation",
        _ operation: @escaping () async throws -> Void
    ) rethrows {
        let expectation = expectation(description: description)

        Task {
            do {
                try await operation()
                expectation.fulfill()
            } catch {
                XCTFail("Async operation failed with error: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: timeout)
    }

    /// Waits for an async operation that returns a value.
    /// - Parameters:
    ///   - timeout: Maximum time to wait (default: 5 seconds)
    ///   - description: Description for the expectation
    ///   - operation: The async operation to execute
    /// - Returns: The result of the async operation
    func waitForAsyncResult<T>(
        timeout: TimeInterval = 5.0,
        description: String = "Async operation",
        _ operation: @escaping () async throws -> T
    ) throws -> T {
        let expectation = expectation(description: description)
        var result: Result<T, Error>?

        Task {
            do {
                let value = try await operation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: timeout)

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw XCTestError(.timeoutWhileWaiting)
        }
    }

    /// Asserts that an async operation throws an error of a specific type.
    /// - Parameters:
    ///   - errorType: The expected error type
    ///   - timeout: Maximum time to wait (default: 5 seconds)
    ///   - message: Optional failure message
    ///   - operation: The async operation expected to throw
    func assertAsyncThrows<E: Error>(
        _ errorType: E.Type,
        timeout: TimeInterval = 5.0,
        message: String = "",
        _ operation: @escaping () async throws -> Void
    ) {
        let expectation = expectation(description: "Expected error of type \(errorType)")

        Task {
            do {
                try await operation()
                XCTFail("Expected error of type \(errorType) but operation succeeded. \(message)")
            } catch {
                XCTAssertTrue(error is E, "Expected error of type \(errorType) but got \(type(of: error)). \(message)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: timeout)
    }
}
