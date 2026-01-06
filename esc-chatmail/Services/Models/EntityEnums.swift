import Foundation

enum ConversationType: String {
    case oneToOne = "oneToOne"
    case group = "group"
    case list = "list"
}

enum ParticipantRole: String {
    case normal = "normal"
    case me = "me"
    case listAddress = "listAddress"
}

enum ParticipantKind: String {
    case from = "from"
    case to = "to"
    case cc = "cc"
    case bcc = "bcc"
}
