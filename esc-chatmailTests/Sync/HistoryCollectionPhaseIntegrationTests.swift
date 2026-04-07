import XCTest
@testable import esc_chatmail

final class HistoryCollectionPhaseIntegrationTests: XCTestCase {
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "HistoryCollectionPhaseIntegrationTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let defaultsSuiteName {
            let defaults = UserDefaults(suiteName: defaultsSuiteName)
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testExecute_returnsTruncatedResultWhenHistoryPaginationExceedsLimit() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setHistoryResponsesByPageToken(makeTruncatedHistoryPages(pageCount: 50))

        let messageFetcher = MessageFetcher(apiClient: mockAPI)
        let historyProcessor = HistoryProcessor()
        let phase = HistoryCollectionPhase(
            messageFetcher: messageFetcher,
            historyProcessor: historyProcessor
        )

        let context = makePhaseContext()
        let startingHistoryId = "1000"
        let result = try await phase.execute(input: startingHistoryId, context: context)

        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.latestHistoryId, startingHistoryId)
        XCTAssertEqual(result.records.count, 50)
        XCTAssertEqual(result.newMessageIds.count, 50)
        XCTAssertEqual(mockAPI.listHistoryCallCount, 50)
    }

    func testExecute_propagatesHistoryIdExpiredForRecoveryHandling() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.listHistoryError = APIError.historyIdExpired

        let messageFetcher = MessageFetcher(apiClient: mockAPI)
        let historyProcessor = HistoryProcessor()
        let phase = HistoryCollectionPhase(
            messageFetcher: messageFetcher,
            historyProcessor: historyProcessor
        )

        do {
            _ = try await phase.execute(input: "start", context: makePhaseContext())
            XCTFail("Expected historyIdExpired error")
        } catch let error as APIError {
            if case .historyIdExpired = error {
                XCTAssertEqual(mockAPI.listHistoryCallCount, 1)
            } else {
                XCTFail("Expected historyIdExpired but got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExecute_keepsDeletionOnlyHistoryRecordsForLaterProcessing() async throws {
        let mockAPI = MockGmailAPIClient()
        let deletedRecord = HistoryRecord(
            id: "history-delete",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: [HistoryMessageDeleted(message: MessageListItem(id: "deleted-message", threadId: nil))],
            labelsAdded: nil,
            labelsRemoved: nil
        )
        mockAPI.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [deletedRecord],
                    nextPageToken: nil,
                    historyId: "1001"
                )
            )
        ])

        let phase = HistoryCollectionPhase(
            messageFetcher: MessageFetcher(apiClient: mockAPI),
            historyProcessor: HistoryProcessor()
        )

        let result = try await phase.execute(input: "1000", context: makePhaseContext())

        XCTAssertEqual(result.records.map(\.id), ["history-delete"])
        XCTAssertTrue(result.newMessageIds.isEmpty)
        XCTAssertEqual(result.latestHistoryId, "1001")
        XCTAssertFalse(result.wasTruncated)
    }

    private func makePhaseContext() -> SyncPhaseContext {
        let testStack = TestCoreDataStack()
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: .shared)

        return SyncPhaseContext(
            coreDataContext: testStack.newBackgroundContext(),
            labelIds: [],
            myAliases: [],
            syncStartTime: Date(),
            progressHandler: { _, _ in },
            failureTracker: failureTracker
        )
    }

    private func makeTruncatedHistoryPages(pageCount: Int) -> [(pageToken: String?, response: HistoryResponse)] {
        var pages: [(pageToken: String?, response: HistoryResponse)] = []

        for index in 0..<pageCount {
            let requestPageToken: String? = index == 0 ? nil : "p\(index)"
            let nextPageToken: String? = "p\(index + 1)"

            let message = GmailMessage(
                id: "m\(index)",
                threadId: "t\(index)",
                labelIds: ["INBOX"],
                snippet: "Snippet \(index)",
                historyId: "\(2000 + index)",
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            )

            let record = HistoryRecord(
                id: "\(3000 + index)",
                messages: nil,
                messagesAdded: [HistoryMessageAdded(message: message)],
                messagesDeleted: nil,
                labelsAdded: nil,
                labelsRemoved: nil
            )

            let response = HistoryResponse(
                history: [record],
                nextPageToken: nextPageToken,
                historyId: "\(4000 + index)"
            )

            pages.append((pageToken: requestPageToken, response: response))
        }

        return pages
    }
}
