import XCTest
@testable import YourAppModule

final class MimeBuilderTests: XCTestCase {
    
    func testBuildNewMessage() {
        let to = ["alice@example.com", "bob@example.com"]
        let from = "sender@example.com"
        let body = "Hello, this is a test message."
        
        let mimeData = MimeBuilder.buildNew(to: to, from: from, body: body)
        let mimeString = String(data: mimeData, encoding: .utf8)!
        
        XCTAssertTrue(mimeString.contains("From: sender@example.com\r\n"))
        XCTAssertTrue(mimeString.contains("To: alice@example.com, bob@example.com\r\n"))
        XCTAssertTrue(mimeString.contains("Date: "))
        XCTAssertTrue(mimeString.contains("Message-ID: <"))
        XCTAssertTrue(mimeString.contains("MIME-Version: 1.0\r\n"))
        XCTAssertTrue(mimeString.contains("Content-Type: text/plain; charset=UTF-8\r\n"))
        XCTAssertTrue(mimeString.contains("Content-Transfer-Encoding: 8bit\r\n"))
        XCTAssertTrue(mimeString.contains("\r\n\r\n"))
        XCTAssertTrue(mimeString.hasSuffix(body))
        
        // Now an empty Subject header should be added
        XCTAssertTrue(mimeString.contains("Subject: \r\n"))
    }
    
    func testBuildReplyMessage() {
        let to = ["alice@example.com"]
        let from = "sender@example.com"
        let body = "This is a reply."
        let subject = "Re: Original Subject"
        let inReplyTo = "<original-message-id@example.com>"
        let references = ["<ref1@example.com>", "<ref2@example.com>"]
        
        let mimeData = MimeBuilder.buildReply(
            to: to,
            from: from,
            body: body,
            subject: subject,
            inReplyTo: inReplyTo,
            references: references
        )
        
        let mimeString = String(data: mimeData, encoding: .utf8)!
        
        XCTAssertTrue(mimeString.contains("From: sender@example.com\r\n"))
        XCTAssertTrue(mimeString.contains("To: alice@example.com\r\n"))
        XCTAssertTrue(mimeString.contains("Subject: Re: Original Subject\r\n"))
        XCTAssertTrue(mimeString.contains("In-Reply-To: <original-message-id@example.com>\r\n"))
        XCTAssertTrue(mimeString.contains("References: <ref1@example.com> <ref2@example.com>\r\n"))
        XCTAssertTrue(mimeString.hasSuffix(body))
    }
    
    func testBase64UrlEncoding() {
        let testData = "Hello+World/Test=".data(using: .utf8)!
        let encoded = MimeBuilder.base64UrlEncode(testData)
        
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertTrue(encoded.contains("-") || encoded.contains("_") || !encoded.contains("+"))
    }
    
    func testDateFormatting() {
        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = MimeBuilder.formatDate(date)
        
        XCTAssertTrue(formatted.contains("2021") || formatted.contains("2020"))
        XCTAssertTrue(formatted.contains(":"))
        
        let regex = try! NSRegularExpression(pattern: #"^[A-Za-z]{3}, \d{1,2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$"#)
        let range = NSRange(location: 0, length: formatted.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: formatted, range: range))
    }
    
    func testMessageIdGeneration() {
        let messageId1 = MimeBuilder.generateMessageId()
        let messageId2 = MimeBuilder.generateMessageId()
        
        XCTAssertNotEqual(messageId1, messageId2)
        
        XCTAssertTrue(messageId1.hasPrefix("<"))
        XCTAssertTrue(messageId1.hasSuffix(">"))
        XCTAssertTrue(messageId1.contains("@"))
        
        let pattern = #"^<[a-f0-9\-]+@[\w\-\.]+>$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: messageId1.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: messageId1, range: range))
    }
    
    func testSubjectPrefixing() {
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply("Test"), "Re: Test")
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply("Re: Test"), "Re: Test")
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply("RE: Test"), "RE: Test")
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply("re: Test"), "re: Test")
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply(""), "")
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply("  "), "")
        XCTAssertEqual(MimeBuilder.prefixSubjectForReply("  Test  "), "Re: Test")
    }
    
    func testNonAsciiSubjectEncoding() {
        let asciiSubject = "Hello World"
        let encodedAscii = MimeBuilder.encodeHeaderIfNeeded(asciiSubject)
        XCTAssertEqual(encodedAscii, asciiSubject)
        
        let unicodeSubject = "Hello 世界 🌍"
        let encodedUnicode = MimeBuilder.encodeHeaderIfNeeded(unicodeSubject)
        XCTAssertTrue(encodedUnicode.hasPrefix("=?UTF-8?B?"))
        XCTAssertTrue(encodedUnicode.hasSuffix("?="))
        
        let base64Part = encodedUnicode
            .replacingOccurrences(of: "=?UTF-8?B?", with: "")
            .replacingOccurrences(of: "?=", with: "")
        
        if let decodedData = Data(base64Encoded: base64Part),
           let decodedString = String(data: decodedData, encoding: .utf8) {
            XCTAssertEqual(decodedString, unicodeSubject)
        } else {
            XCTFail("Failed to decode base64 encoded subject")
        }
    }
    
    func testCRLFLineEndings() {
        let to = ["test@example.com"]
        let from = "sender@example.com"
        let body = "Line 1\nLine 2\nLine 3"

        let mimeData = MimeBuilder.buildNew(to: to, from: from, body: body)
        let mimeString = String(data: mimeData, encoding: .utf8)!

        let headerBody = mimeString.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(headerBody.count, 2)

        let headers = headerBody[0]
        let headerLines = headers.components(separatedBy: "\r\n")

        for line in headerLines where !line.isEmpty {
            XCTAssertFalse(line.contains("\n") && !line.contains("\r\n"))
        }
    }

    func testFromHeaderWithName() {
        let to = ["alice@example.com"]
        let from = "sender@example.com"
        let fromName = "John Doe"
        let body = "Test message with name"

        let mimeData = MimeBuilder.buildNew(to: to, from: from, fromName: fromName, body: body)
        let mimeString = String(data: mimeData, encoding: .utf8)!

        XCTAssertTrue(mimeString.contains("From: John Doe <sender@example.com>\r\n"))
    }

    func testFromHeaderWithSpecialCharacterName() {
        let to = ["alice@example.com"]
        let from = "sender@example.com"
        let fromName = "John \"Johnny\" Doe"
        let body = "Test message with special name"

        let mimeData = MimeBuilder.buildNew(to: to, from: from, fromName: fromName, body: body)
        let mimeString = String(data: mimeData, encoding: .utf8)!

        XCTAssertTrue(mimeString.contains("From: \"John \\\"Johnny\\\" Doe\" <sender@example.com>\r\n"))
    }

    func testFromHeaderWithUnicodeName() {
        let to = ["alice@example.com"]
        let from = "sender@example.com"
        let fromName = "José García"
        let body = "Test message with unicode name"

        let mimeData = MimeBuilder.buildNew(to: to, from: from, fromName: fromName, body: body)
        let mimeString = String(data: mimeData, encoding: .utf8)!

        // The name should be encoded as it contains non-ASCII characters
        XCTAssertTrue(mimeString.contains("=?UTF-8?B?") && mimeString.contains("<sender@example.com>"))
    }

    func testFromHeaderWithoutName() {
        let to = ["alice@example.com"]
        let from = "sender@example.com"
        let body = "Test message without name"

        let mimeData = MimeBuilder.buildNew(to: to, from: from, fromName: nil, body: body)
        let mimeString = String(data: mimeData, encoding: .utf8)!

        // Should just have the email without angle brackets
        XCTAssertTrue(mimeString.contains("From: sender@example.com\r\n"))
    }
}