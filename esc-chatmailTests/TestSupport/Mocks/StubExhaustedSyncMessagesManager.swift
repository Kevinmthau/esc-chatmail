import Foundation
@testable import esc_chatmail

/// Scriptable `ExhaustedSyncMessagesManaging` for the banner model's tests, and
/// an empty one for views that need a model but no banner (the Mac sidebar's
/// hosted suites).
actor StubExhaustedSyncMessagesManager: ExhaustedSyncMessagesManaging {
    private var exhaustedIds: [String]?
    private var retryAnswer: Bool
    private(set) var retryCalls = 0
    private var fetches = 0

    func fetchCount() -> Int {
        fetches
    }

    init(exhaustedIds: [String]? = [], retryAnswer: Bool = false) {
        self.exhaustedIds = exhaustedIds
        self.retryAnswer = retryAnswer
    }

    func setExhaustedIds(_ ids: [String]?) {
        exhaustedIds = ids
    }

    func fetchExhaustedMessageIds() async -> [String]? {
        fetches += 1
        return exhaustedIds
    }

    func retryExhaustedMessages() async -> Bool {
        retryCalls += 1
        return retryAnswer
    }
}

extension ExhaustedSyncMessagesModel {
    /// A model that never shows its banner.
    @MainActor
    static func showingNothing() -> ExhaustedSyncMessagesModel {
        ExhaustedSyncMessagesModel(
            manager: StubExhaustedSyncMessagesManager(),
            accountEmail: { nil },
            requestSync: {}
        )
    }
}
