import Foundation

/// Nintendo Account mail as the chat showed it: a digital purchase receipt and a
/// Nintendo Switch Online automatic-renewal notice, plain label/value text with
/// `<br>` line breaks and no headings, images or action links. The receipt's
/// totals section below its divider was not visible in the reported screenshot;
/// the `Price` / `Total` lines here are representative, not transcribed.
enum NintendoNoticeFixtures {
    static let senderEmail = "no-reply@accounts.nintendo.com"
    static let senderName = "Nintendo"

    static let purchaseSubject = "Thank you for your purchase"
    static let purchaseBodyText = """
    This is an automatically generated email from Nintendo.

    ------------------------

    Dear Player,

    Thank you for your recent digital purchase from Nintendo. Details of this transaction are below:

    Transaction ID: 52724694283
    Transaction Date: 11/1/2026 05:58:10 (24H PST)

    Purchased Membership: Nintendo Switch Online + Expansion Pack individual 12-month (365-day) membership

    If you purchased a family membership, you can check and add family members for your Nintendo Account under Family Group on the following page:
    https://accounts.nintendo.com/family

    You can see the deadline to turn off automatic renewal in the following locations:

    ▼ On your Nintendo Switch 2 or Nintendo Switch
    ① Open Nintendo eShop
    ② Go to Nintendo Switch Online under Account Information (the icon in the top-right corner)

    ▼ On your PC or smart device
    • Sign in to your Nintendo Account at https://ec.nintendo.com/my/membership

    ------------------------

    Price: $49.99
    Tax: $4.37
    Total: $54.36
    """

    static let renewalSubject = "Your Nintendo Switch Online membership is set for automatic renewal"
    static let renewalBodyText = """
    This is an automatically generated email from Nintendo.

    ------------------------

    Dear Player,

    Your Nintendo Switch Online + Expansion Pack individual 12-month (365-day) membership is set for automatic renewal.

    Details:

    Nintendo Account: player@example.com
    Automatic renewal term: 365 d
    Price (subject to applicable taxes): $49.99
    Deadline to turn off automatic renewal: 10/30/2027 06:58 (24H PDT)

    ------------------------

    Duration and Payment Method for Automatic Renewal

    If automatic renewal is set, your Nintendo Switch Online membership ("Subscription") will automatically renew for successive periods matching the automatic renewal term shown above at the then-current price, plus applicable taxes ("Subscription Amount"), unless you turn off automatic renewal.

    On the renewal date, the Subscription Amount will be charged to the payment method on file.
    """

    /// The body as Nintendo's HTML part carries it: the same lines, `<br>`-separated.
    static func html(from bodyText: String) -> String {
        let escaped = bodyText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <html>
        <body>
        \(escaped.replacingOccurrences(of: "\n", with: "<br>\n"))
        </body>
        </html>
        """
    }
}
