import Foundation
import GoogleSignIn
@testable import esc_chatmail

/// A `GIDGoogleUser` a test can make, for the paths of `AuthSession.restorePreviousSignIn()`
/// after the SDK answered with a user: the account preparation, the credential persistence,
/// the reopen and the publish.
///
/// GoogleSignIn makes its users from an `OIDAuthState` in an initializer its public header
/// does not declare, and earlier suites took that to mean no test could make one. The class
/// declares no initializer of its own in that header, so a subclass starts from `NSObject`'s
/// `init()` and answers the four properties the restore reads: `profile`, `grantedScopes`,
/// `accessToken` and `refreshToken`. Every other property reads the superclass's empty
/// state, so nothing under test may ask for `configuration`, `idToken`,
/// `fetcherAuthorizer` or `refreshTokensIfNeeded`.
///
/// Make it inside the stub closure that hands it over, never outside it: it is not
/// `Sendable`, and CI's Swift 6.2 refuses a capture of a non-`Sendable` value in a
/// `@Sendable` closure that Swift 6.4 accepts.
final class StubGoogleUser: GIDGoogleUser {
    private let stubProfile: GIDProfileData?
    private let stubGrantedScopes: [String]?
    private let stubAccessToken: GIDToken
    private let stubRefreshToken: GIDToken

    /// A user with the Gmail scope granted, whose profile has `email` (no profile at all
    /// for nil).
    init(
        email: String?,
        name: String = "Stub User",
        grantedScopes: [String]? = [GoogleConfig.gmailModifyScope],
        accessToken: String = "stub-access-token",
        refreshToken: String = "stub-refresh-token",
        accessTokenExpirationDate: Date = Date().addingTimeInterval(3600)
    ) {
        stubProfile = email.map { StubGoogleProfile(email: $0, name: name) }
        stubGrantedScopes = grantedScopes
        stubAccessToken = Self.makeToken(accessToken, expirationDate: accessTokenExpirationDate)
        stubRefreshToken = Self.makeToken(refreshToken, expirationDate: nil)
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var profile: GIDProfileData? { stubProfile }
    override var grantedScopes: [String]? { stubGrantedScopes }
    override var accessToken: GIDToken { stubAccessToken }
    override var refreshToken: GIDToken { stubRefreshToken }

    /// A `GIDToken`, whose initializers are not public either, made through its own
    /// `NSSecureCoding` (the keys of `GIDToken.m`'s `encodeWithCoder:` in GoogleSignIn 9.0.0).
    /// A key renamed by a later GoogleSignIn decodes as nil and fails this loudly.
    private static func makeToken(_ tokenString: String, expirationDate: Date?) -> GIDToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("GIDToken", for: StubGoogleTokenArchive.self)
        archiver.encode(
            StubGoogleTokenArchive(tokenString: tokenString, expirationDate: expirationDate),
            forKey: NSKeyedArchiveRootObjectKey
        )
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData),
              let token = unarchiver.decodeObject(of: GIDToken.self, forKey: NSKeyedArchiveRootObjectKey),
              token.tokenString == tokenString else {
            preconditionFailure("GIDToken no longer decodes from the keys StubGoogleUser writes")
        }
        return token
    }
}

/// The profile `StubGoogleUser` answers with. Named for the Objective-C runtime, as an
/// `NSCoding` class must be when it is private.
@objc(StubGoogleProfile)
private final class StubGoogleProfile: GIDProfileData {
    private let stubEmail: String
    private let stubName: String

    init(email: String, name: String) {
        stubEmail = email
        stubName = name
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var email: String { stubEmail }
    override var name: String { stubName }
}

/// Writes what `GIDToken` reads in `initWithCoder:`, archived under its class name.
@objc(StubGoogleTokenArchive)
private final class StubGoogleTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    private let tokenString: String
    private let expirationDate: Date?

    init(tokenString: String, expirationDate: Date?) {
        self.tokenString = tokenString
        self.expirationDate = expirationDate
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func encode(with coder: NSCoder) {
        coder.encode(tokenString as NSString, forKey: "tokenString")
        coder.encode(expirationDate as NSDate?, forKey: "expirationDate")
    }
}
