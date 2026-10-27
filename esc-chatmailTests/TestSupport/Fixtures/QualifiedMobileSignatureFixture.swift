import Foundation

/// Anonymized reproduction of an Outlook reply from a Taiwanese manufacturer whose
/// signature leaked into the chat bubble. Names, numbers and hosts are invented; the
/// row shapes are preserved: a "Tel:" row with no space after the colon, mobile labels
/// qualified by a carrier or region code ("TWM Mobile:", "CQ Mobile:"), an MVPN short
/// number below the seven-digit phone floor, and an "Email:" row last. The upward
/// contact scan used to stop at the MVPN row with a single contact. The same HTML is
/// the golden corpus case `html_outlook_carrier_labeled_mobiles_and_mvpn_signature_removed`.
enum QualifiedMobileSignatureFixture {
    static let html = """
    <div class="WordSection1"><p class="MsoNormal">Hi team,</p>\
    <p class="MsoNormal">Could you please let us know your available time on November 6, or suggest another suitable time?</p>\
    <p class="MsoNormal">Thank you for your support!</p>\
    <p class="MsoNormal">Thanks and Best Regards,</p>\
    <p class="MsoNormal">Lin Chen</p>\
    <p class="MsoNormal">Example Computer Inc.</p>\
    <p class="MsoNormal">Tel:+886-3-555-0123 Ext. 15000</p>\
    <p class="MsoNormal">TWM Mobile: 0912555018</p>\
    <p class="MsoNormal">CQ Mobile: 13800555018</p>\
    <p class="MsoNormal">MVPN 655018</p>\
    <p class="MsoNormal">Email: <a href="mailto:lin.chen@example.test">lin.chen@example.test</a></p></div>
    """

    static let expectedChatText = "Hi team,\n\nCould you please let us know your available time on November 6, " +
        "or suggest another suitable time?\n\nThank you for your support!\n\nThanks and Best Regards,\n\nLin Chen"

    /// What the bubble showed before the fix: the whole signature below the name.
    static let leakedChatText = expectedChatText +
        "\n\nExample Computer Inc.\n\nTel:+886-3-555-0123 Ext. 15000\n\nTWM Mobile: 0912555018" +
        "\n\nCQ Mobile: 13800555018\n\nMVPN 655018\n\nEmail: lin.chen@example.test"
}
