import Foundation

struct GoogleConfig {
    static let clientId = "999923476073-b4m4r3o96gv30rqmo71qo210oa46au74.apps.googleusercontent.com"
    static let apiKey = "AIzaSyAnVWdfhCGB0raSuwStoMl6U3368E9-gxk"
    static let projectNumber = "999923476073"
    static let projectId = "esc-gmail-client"
    static let redirectURI = "com.googleusercontent.apps.999923476073-b4m4r3o96gv30rqmo71qo210oa46au74"
    
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
}