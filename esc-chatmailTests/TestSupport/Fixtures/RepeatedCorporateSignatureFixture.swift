import Foundation

/// Synthetic reproduction of an Outlook reply with a long, repeated corporate
/// signature. Names, contact details, message text, and reference values are
/// invented; no original email or attachments are included.
enum RepeatedCorporateSignatureFixture {
    enum Footer {
        case coverage
        case operations
    }

    static let bodyParagraphs = [
        "Hi Avery,",
        "The reviewer confirmed that the report contained an unrelated entry, so it has been removed from the revised proposal. The updated proposal is now ready for your review.",
        "I have attached the revised documents. Please confirm whether you would like us to proceed with the requested change.",
        "We will also remove the old item from your account.",
        "Thank you!"
    ]
    static let signOff = "Sincerely,"
    static let senderName = "Taylor Morgan"
    static let priorReply = "I will check the report and send an update once the reviewer responds."
    static let expectedChatText = (bodyParagraphs + [signOff, senderName]).joined(separator: "\n\n")
    static let newPostscript = "P.S. Please wait until Monday before making the requested change."
    static let oldPostscript = "P.S. Please use the earlier draft when reviewing the requested change."

    static let contactLines = [
        "Senior Account Manager | CA License #0A00000",
        "Personal Lines",
        "West Division",
        "CA Agency License: 0B00000",
        "100 Example Blvd., Floor 2",
        "Sample City, CA 90000",
        "Direct: 202-555-0101",
        "Fax: 202-555-0102",
        "Email: taylor@example.test",
        "Bill Pay Online: billing.example.test"
    ]

    static func footerParagraphs(_ footer: Footer) -> [String] {
        switch footer {
        case .coverage:
            [
                "***Changes in payment reminders for our customers***",
                "Our team previously sent individual reminders when a payment was approaching. Beginning this month, customers should consult their statements for the payment schedule. Please arrange each payment before its due date so your selected services remain active.",
                "Coverage requests require written confirmation from an authorized representative of Example Services or the applicable provider before they take effect. Please contact your representative if you have questions about an existing request."
            ]
        case .operations:
            [
                "***Equipment collection arrangements for visitors***",
                "Our workshop prepares each reserved collection before the scheduled visit. Visitors should use the east entrance and check the collection board when they arrive. Please bring a copy of the reservation so the workshop team can locate the prepared equipment.",
                "Collection arrangements are recorded in the workshop schedule after a coordinator has reviewed the request. If the loading area is occupied, please wait in the marked visitor space until the coordinator confirms that your equipment is ready."
            ]
        }
    }

    static func plainText(
        footer: Footer = .coverage,
        includeHistory: Bool = true,
        currentPostscript: String? = nil,
        historicalPostscript: String? = nil,
        historicalFooter: Footer? = nil
    ) -> String {
        let current = (bodyParagraphs + [plainSignature(footer)] + [currentPostscript].compactMap { $0 })
            .joined(separator: "\r\n\r\n")
        guard includeHistory else { return current }

        return current + "\r\n\r\n" + """
        From: Avery Parker <avery@example.test>
        Sent: Thursday, August 20, 2026 10:00 AM
        To: Taylor Morgan <taylor@example.test>
        Subject: Re: Account update

        Thanks for checking.

        On Thu, Aug 20, 2026 at 9:00 AM Taylor Morgan <taylor@example.test> wrote:
        \(priorReply)

        \(plainSignature(historicalFooter ?? footer, linkedContactDetails: true))
        \(historicalPostscript.map { "\n\n" + $0 } ?? "")
        """.replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func html(
        footer: Footer = .coverage,
        includeHistory: Bool = true,
        currentPostscript: String? = nil,
        historicalPostscript: String? = nil,
        historicalFooter: Footer? = nil
    ) -> String {
        let current = paragraphs(bodyParagraphs) + htmlSignature(footer)
            + (currentPostscript.map { paragraphs([$0]) } ?? "")
        let history = includeHistory ? """
        <div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in">
          <p class="MsoNormal"><b>From:</b> Avery Parker &lt;avery@example.test&gt;<br>
          <b>Sent:</b> Thursday, August 20, 2026 10:00 AM<br>
          <b>To:</b> Taylor Morgan &lt;taylor@example.test&gt;<br>
          <b>Subject:</b> Re: Account update</p>
        </div>
        <p class="MsoNormal">Thanks for checking.</p>
        <div class="gmail_quote">
          <div>On Thu, Aug 20, 2026 at 9:00 AM Taylor Morgan &lt;taylor@example.test&gt; wrote:</div>
          <blockquote style="border-left:solid #cccccc 1.0pt;padding-left:6.0pt">
            \(paragraphs([priorReply]))
            \(htmlSignature(historicalFooter ?? footer, linkedContactDetails: true))
            \(historicalPostscript.map { paragraphs([$0]) } ?? "")
          </blockquote>
        </div>
        """ : ""

        return """
        <html xmlns:o="urn:schemas-microsoft-com:office:office">
        <head><meta name="Generator" content="Microsoft Word 15 (filtered medium)">
        <style>p.MsoNormal { margin:0in; font-size:12pt; font-family:Aptos,sans-serif; }</style></head>
        <body><div class="WordSection1">\(current)\(history)</div></body>
        </html>
        """
    }

    private static func plainSignature(_ footer: Footer, linkedContactDetails: Bool = false) -> String {
        let contacts = contactLines.map { line in
            guard linkedContactDetails else { return line }
            if line.hasPrefix("Email:") { return line + "<mailto:taylor@example.test>" }
            if line.hasPrefix("Direct:") { return line + "<tel:2025550101>" }
            if line.hasPrefix("Fax:") { return line + "<tel:2025550102>" }
            if line.hasPrefix("Bill Pay") { return line + "<http://billing.example.test>" }
            if line.hasPrefix("100 Example") { return line + "<https://maps.example.test/office>" }
            return line
        }
        let footerText = footerParagraphs(footer)
        return ([signOff, senderName] + contacts).joined(separator: "\n")
            + "\n\n" + footerText.prefix(2).joined(separator: "\n")
            + "\n\n[Example Services logo]\n" + footerText[2]
    }

    private static func htmlSignature(_ footer: Footer, linkedContactDetails: Bool = false) -> String {
        let contacts = contactLines.map { line in
            if line.hasPrefix("Email:") {
                return "Email: <a href=\"mailto:taylor@example.test\">taylor@example.test</a>"
            }
            if linkedContactDetails && line.hasPrefix("Bill Pay") {
                return "Bill Pay Online: <a href=\"http://billing.example.test\">billing.example.test</a>"
            }
            if linkedContactDetails && line.hasPrefix("Direct:") {
                return "Direct: <a href=\"tel:2025550101\">202-555-0101</a>"
            }
            if linkedContactDetails && line.hasPrefix("100 Example") {
                return "<a href=\"https://maps.example.test/office\">\(line)</a>"
            }
            return line
        }.joined(separator: "<br>\n")
        let footerText = footerParagraphs(footer)
        return """
        <p class="MsoNormal"><o:p>&nbsp;</o:p></p>
        <p class="MsoNormal" style="line-height:15.0pt"><b><span style="font-size:14pt">\(signOff)</span></b></p>
        <p class="MsoNormal" style="margin-bottom:6pt"><b><span style="font-size:10.5pt">\(senderName)<br></span></b>
          <span style="font-size:9pt">\(contacts)<o:p></o:p></span></p>
        <p class="MsoNormal" style="margin-bottom:6pt"><b><span style="font-size:9pt;color:#3399FF">
          \(footerText[0])<br>\(footerText[1])<br></span></b><br>
          <img width="229" height="27" src="cid:example-logo.png" alt="Example Services logo"></p>
        \(paragraphs([footerText[2]]))
        """
    }

    private static func paragraphs(_ lines: [String]) -> String {
        lines.map { "<p class=\"MsoNormal\">\($0)<o:p></o:p></p>" }.joined(separator: "\n")
    }
}
