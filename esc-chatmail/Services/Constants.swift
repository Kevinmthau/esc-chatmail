import Foundation

struct GoogleConfig {
    // Read configuration from Info.plist (which uses xcconfig values)
    private static let bundle = Bundle.main
    private static let infoDictionary = bundle.infoDictionary ?? [:]

    static func printConfigurationStatus() {
        #if DEBUG
        print("📋 Configuration Status:")
        print("  GOOGLE_CLIENT_ID from plist: \(bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") ?? "nil")")
        print("  Using fallback values: \(!clientId.isEmpty)")
        print("  Note: To use xcconfig files, link them in Xcode project settings")
        #endif
    }

    static let clientId: String = {
        guard let clientId = bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
              !clientId.isEmpty,
              !clientId.contains("$") else {  // Check if it's still a variable like $(GOOGLE_CLIENT_ID)
            // Use the actual value temporarily until xcconfig is properly linked
            return "999923476073-b4m4r3o96gv30rqmo71qo210oa46au74.apps.googleusercontent.com"
        }
        return clientId
    }()

    static let apiKey: String = {
        guard let apiKey = bundle.object(forInfoDictionaryKey: "GOOGLE_API_KEY") as? String,
              !apiKey.isEmpty,
              !apiKey.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "AIzaSyAnVWdfhCGB0raSuwStoMl6U3368E9-gxk"
        }
        return apiKey
    }()

    static let projectNumber: String = {
        guard let projectNumber = bundle.object(forInfoDictionaryKey: "GOOGLE_PROJECT_NUMBER") as? String,
              !projectNumber.isEmpty,
              !projectNumber.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "999923476073"
        }
        return projectNumber
    }()

    static let projectId: String = {
        guard let projectId = bundle.object(forInfoDictionaryKey: "GOOGLE_PROJECT_ID") as? String,
              !projectId.isEmpty,
              !projectId.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "esc-gmail-client"
        }
        return projectId
    }()

    static let redirectURI: String = {
        guard let redirectURI = bundle.object(forInfoDictionaryKey: "GOOGLE_REDIRECT_URI") as? String,
              !redirectURI.isEmpty,
              !redirectURI.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "com.googleusercontent.apps.999923476073-b4m4r3o96gv30rqmo71qo210oa46au74"
        }
        return redirectURI
    }()

    static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.modify"
    ]
}

struct APIEndpoints {
    static let baseURL = "https://gmail.googleapis.com/gmail/v1"
    
    static func profile() -> String {
        "\(baseURL)/users/me/profile"
    }
    
    static func labels() -> String {
        "\(baseURL)/users/me/labels"
    }
    
    static func messages() -> String {
        "\(baseURL)/users/me/messages"
    }
    
    static func message(id: String) -> String {
        "\(baseURL)/users/me/messages/\(id)"
    }
    
    static func modifyMessage(id: String) -> String {
        "\(baseURL)/users/me/messages/\(id)/modify"
    }
    
    static func batchModify() -> String {
        "\(baseURL)/users/me/messages/batchModify"
    }
    
    static func history() -> String {
        "\(baseURL)/users/me/history"
    }
    
    static func sendAs() -> String {
        "\(baseURL)/users/me/settings/sendAs"
    }
    
    static func attachment(messageId: String, attachmentId: String) -> String {
        "\(baseURL)/users/me/messages/\(messageId)/attachments/\(attachmentId)"
    }
}