import XCTest
@testable import esc_chatmail

class ConversationGrouperTests: XCTestCase {
    
    func testParticipantSetGrouping() {
        // Test that conversations are grouped by unique participant sets
        let myEmail = "me@example.com"
        let aliases = ["me.alias@example.com", "another.me@example.com"]
        let grouper = ConversationGrouper(myEmail: myEmail, aliases: aliases)
        
        // Test 1: Same participants, different order - should produce same key
        let headers1 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com, bob@example.com"),
            MessageHeader(name: "Cc", value: "charlie@example.com")
        ]
        
        let headers2 = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@example.com"),
            MessageHeader(name: "Cc", value: "bob@example.com, charlie@example.com")
        ]
        
        let result1 = grouper.computeConversationKey(from: headers1)
        let result2 = grouper.computeConversationKey(from: headers2)
        
        XCTAssertEqual(result1.key, result2.key, "Same participant set should produce same conversation key")
        XCTAssertEqual(result1.participants, result2.participants, "Participant sets should be identical")
        XCTAssertEqual(result1.type, .group, "Should be identified as group conversation")
        
        // Test 2: Different participants - should produce different keys
        let headers3 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com, david@example.com")
        ]
        
        let result3 = grouper.computeConversationKey(from: headers3)
        XCTAssertNotEqual(result1.key, result3.key, "Different participant sets should produce different keys")
        
        // Test 3: To vs Cc should not matter
        let headers4 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com"),
            MessageHeader(name: "Cc", value: "bob@example.com")
        ]
        
        let headers5 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "bob@example.com"),
            MessageHeader(name: "Cc", value: "alice@example.com")
        ]
        
        let result4 = grouper.computeConversationKey(from: headers4)
        let result5 = grouper.computeConversationKey(from: headers5)
        
        XCTAssertEqual(result4.key, result5.key, "Position in To vs Cc should not affect conversation key")
    }
    
    func testBccIsIgnored() {
        // Test that Bcc recipients are excluded from conversation grouping
        let grouper = ConversationGrouper(myEmail: "me@example.com")
        
        let headers1 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com"),
            MessageHeader(name: "Bcc", value: "secret@example.com")
        ]
        
        let headers2 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com")
        ]
        
        let result1 = grouper.computeConversationKey(from: headers1)
        let result2 = grouper.computeConversationKey(from: headers2)
        
        XCTAssertEqual(result1.key, result2.key, "Bcc should be ignored in conversation grouping")
        XCTAssertEqual(result1.participants, Set(["alice@example.com"]), "Bcc recipient should not be in participants")
    }
    
    func testAliasesExcluded() {
        // Test that all user aliases are properly excluded from participant set
        let myEmail = "me@gmail.com"
        let aliases = ["me+work@gmail.com", "my.name@gmail.com"]
        let grouper = ConversationGrouper(myEmail: myEmail, aliases: aliases)
        
        let headers = [
            MessageHeader(name: "From", value: "alice@example.com"),
            MessageHeader(name: "To", value: "me@gmail.com, me+work@gmail.com, bob@example.com"),
            MessageHeader(name: "Cc", value: "my.name@gmail.com, charlie@example.com")
        ]
        
        let result = grouper.computeConversationKey(from: headers)
        
        let expectedParticipants = Set(["alice@example.com", "bob@example.com", "charlie@example.com"])
        XCTAssertEqual(result.participants, expectedParticipants, "All user aliases should be excluded from participants")
    }
    
    func testListIdTakesPrecedence() {
        // Test that List-Id header takes precedence over participant-based grouping
        let grouper = ConversationGrouper(myEmail: "me@example.com")
        
        let headers1 = [
            MessageHeader(name: "From", value: "sender1@example.com"),
            MessageHeader(name: "To", value: "list@example.com"),
            MessageHeader(name: "List-Id", value: "<mylist.example.com>")
        ]
        
        let headers2 = [
            MessageHeader(name: "From", value: "sender2@example.com"),
            MessageHeader(name: "To", value: "list@example.com"),
            MessageHeader(name: "Cc", value: "extra@example.com"),
            MessageHeader(name: "List-Id", value: "<mylist.example.com>")
        ]
        
        let result1 = grouper.computeConversationKey(from: headers1)
        let result2 = grouper.computeConversationKey(from: headers2)
        
        XCTAssertEqual(result1.key, result2.key, "Messages with same List-Id should have same conversation key")
        XCTAssertEqual(result1.type, .list, "Should be identified as list conversation")
        XCTAssertTrue(result1.participants.isEmpty, "List conversations should have empty participant set")
    }
    
    func testGmailNormalization() {
        // Test Gmail-specific email normalization (dots and plus addressing)
        let grouper = ConversationGrouper(myEmail: "me@example.com")
        
        let headers1 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "john.doe@gmail.com")
        ]
        
        let headers2 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "johndoe+label@gmail.com")
        ]
        
        let result1 = grouper.computeConversationKey(from: headers1)
        let result2 = grouper.computeConversationKey(from: headers2)
        
        XCTAssertEqual(result1.key, result2.key, "Gmail addresses should be normalized (dots removed, plus addressing ignored)")
        XCTAssertEqual(result1.participants, Set(["johndoe@gmail.com"]), "Gmail address should be normalized")
    }
    
    func testMultipleRecipientsInSingleHeader() {
        // Test parsing of multiple recipients in a single header field
        let grouper = ConversationGrouper(myEmail: "me@example.com")
        
        let headers = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "\"Alice Smith\" <alice@example.com>, Bob Jones <bob@example.com>, charlie@example.com")
        ]
        
        let result = grouper.computeConversationKey(from: headers)
        
        let expectedParticipants = Set([
            "alice@example.com",
            "bob@example.com", 
            "charlie@example.com"
        ])
        XCTAssertEqual(result.participants, expectedParticipants, "Should extract all emails from comma-separated list")
    }
    
    func testConversationTypes() {
        // Test correct identification of conversation types
        let grouper = ConversationGrouper(myEmail: "me@example.com")
        
        // One-to-one conversation
        let headers1 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com")
        ]
        let result1 = grouper.computeConversationKey(from: headers1)
        XCTAssertEqual(result1.type, .oneToOne, "Should be identified as one-to-one conversation")
        
        // Group conversation
        let headers2 = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "alice@example.com, bob@example.com")
        ]
        let result2 = grouper.computeConversationKey(from: headers2)
        XCTAssertEqual(result2.type, .group, "Should be identified as group conversation")
        
        // List conversation
        let headers3 = [
            MessageHeader(name: "From", value: "sender@example.com"),
            MessageHeader(name: "To", value: "list@example.com"),
            MessageHeader(name: "List-Id", value: "<mylist.example.com>")
        ]
        let result3 = grouper.computeConversationKey(from: headers3)
        XCTAssertEqual(result3.type, .list, "Should be identified as list conversation")
    }
    
    func testEmptyParticipantSet() {
        // Test when all recipients are user's own aliases
        let grouper = ConversationGrouper(myEmail: "me@example.com", aliases: ["myself@example.com"])
        
        let headers = [
            MessageHeader(name: "From", value: "me@example.com"),
            MessageHeader(name: "To", value: "myself@example.com")
        ]
        
        let result = grouper.computeConversationKey(from: headers)
        
        XCTAssertTrue(result.participants.isEmpty, "Should have empty participant set when only user aliases")
        XCTAssertEqual(result.type, .oneToOne, "Should still be oneToOne even with empty participant set")
    }
}