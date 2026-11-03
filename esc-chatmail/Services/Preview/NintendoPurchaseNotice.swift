/// Card fields read from a Nintendo purchase receipt or membership
/// automatic-renewal notice.
struct NintendoPurchaseNotice: Equatable {
    let title: String
    let subtitle: String?
    let amount: String?
    let status: String
    let detailLine: String?
}
