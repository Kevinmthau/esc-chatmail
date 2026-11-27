import XCTest
@testable import esc_chatmail

/// What a launch restore does with the Google session when the account preparation
/// refused it (architecture review 2026-11, `account-boundary-auth#4`). The restore's own
/// use of it, a queued sign-out checked first, is pinned in `AuthSessionTests`.
final class AuthRestorePreparationPolicyTests: XCTestCase {
    // Revert-check: fails if `AuthRestorePreparationPolicy.restoreDisposition(after:)`
    // changes any mapping. A new `LocalAccountIsolationStage` fails the key check here
    // until it has an explicit entry: every stage needs its own answer to whether it
    // changed anything.
    func testRestoreDisposition_everyStage_isDecided() {
        let expected: [LocalAccountIsolationStage: AuthRestoreReopenPolicy.RestoreDisposition] = [
            .markerUnreadable: .retryKeepingCredentials,
            .storeUninspectable: .retryKeepingCredentials,
            .resetRequired: .discardCredentials,
            .resetFailed: .discardCredentials,
            .recoveryFileRemovalFailed: .discardCredentials
        ]

        XCTAssertEqual(
            Set(expected.keys),
            Set(LocalAccountIsolationStage.allCases),
            "A new stage must make an explicit credential-disposition decision"
        )
        for (stage, disposition) in expected {
            XCTAssertEqual(
                AuthRestorePreparationPolicy.restoreDisposition(after: stage),
                disposition,
                "stage: \(stage)"
            )
            XCTAssertEqual(
                AuthRestorePreparationPolicy.restoreDisposition(
                    afterPreparationFailure: AuthError.localAccountIsolationFailed(stage, StageFailure())
                ),
                disposition,
                "The thrown error is read by its stage (stage: \(stage))"
            )
        }
    }

    // Revert-check: fails if `restoreDisposition(afterPreparationFailure:)` keeps the
    // credentials for an error that carries no stage. A missing address cannot be checked
    // against the store on any later attempt, and an unclassified error fails closed, as
    // every refusal did before the stages.
    func testRestoreDisposition_errorWithNoStage_discardsCredentials() {
        let errors: [Error] = [
            AuthError.missingAccountEmail,
            AuthError.tokenPersistenceFailed(StageFailure()),
            CancellationError(),
            StageFailure()
        ]
        for error in errors {
            XCTAssertEqual(
                AuthRestorePreparationPolicy.restoreDisposition(afterPreparationFailure: error),
                .discardCredentials,
                "\(error)"
            )
        }
    }

    // A refused account is never published, whatever the stage. The restore's catch
    // treats `.publishSession` as a rejection, but no stage may ask for it.
    // Revert-check: fails if `restoreDisposition(after:)` answers `.publishSession` for
    // any stage.
    func testRestoreDisposition_anyStage_neverPublishes() {
        for stage in LocalAccountIsolationStage.allCases {
            XCTAssertNotEqual(AuthRestorePreparationPolicy.restoreDisposition(after: stage), .publishSession)
        }
    }

    // Revert-check: fails if `AuthError.localAccountIsolationStage` answers a stage for an
    // error that is not `localAccountIsolationFailed`, which would let the policy keep the
    // credentials for it.
    func testLocalAccountIsolationStage_otherAuthErrors_isNil() {
        XCTAssertEqual(
            AuthError.localAccountIsolationFailed(.storeUninspectable, StageFailure()).localAccountIsolationStage,
            .storeUninspectable
        )
        XCTAssertNil(AuthError.missingAccountEmail.localAccountIsolationStage)
        XCTAssertNil(AuthError.cleanupPrerequisitePersistenceFailed(StageFailure()).localAccountIsolationStage)
    }
}

private struct StageFailure: Error {}
