import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ForwardAttachmentSelectionTests: XCTestCase {
    func testForwardPreservesDifferentPartsWithMatchingMetadataAndDifferentBytes() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let message = MessageBuilder().withId("same-name-forward").build(in: context)
        AttachmentPaths.setupDirectories()
        let paths = ["local_forward-selection-a", "local_forward-selection-b"].map {
            AttachmentPaths.originalPath(idOrUUID: $0, ext: "pdf")
        }
        defer { paths.forEach { AttachmentPaths.deleteFile(at: $0) } }

        for (index, contents) in [Data("AAAA".utf8), Data("BBBB".utf8)].enumerated() {
            XCTAssertTrue(AttachmentPaths.saveData(contents, to: paths[index]))
            _ = AttachmentBuilder()
                .withId("local_forward-selection-\(index)")
                .withFilename("report.pdf")
                .withMimeType("application/pdf")
                .withByteSize(4)
                .withLocalURL(paths[index])
                .downloaded()
                .forMessage(message)
                .build(in: context)
        }

        let selected = message.attachmentsForForwarding
        XCTAssertEqual(selected.count, 2)
        XCTAssertEqual(Set(selected.compactMap { AttachmentPaths.loadData(from: $0.localURL) }),
                       Set([Data("AAAA".utf8), Data("BBBB".utf8)]))
    }

    func testForwardPreservesDistinctPartsEvenWhenTheirContentIDsMatch() {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let message = MessageBuilder().withId("repeated-cid-forward").build(in: context)
        for id in ["part-a", "part-b"] {
            _ = AttachmentBuilder().withId(id).withContentId("reused-cid")
                .forMessage(message).build(in: context)
        }
        XCTAssertEqual(message.attachmentsForForwarding.compactMap(\.id), ["part-a", "part-b"])
    }

    func testForwardCollapsesOnlyRepeatedSourceAttachmentIdentity() {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let message = MessageBuilder().withId("repeated-source-forward").build(in: context)
        for _ in 0..<2 {
            _ = AttachmentBuilder().withId("same-source-part").forMessage(message).build(in: context)
        }
        XCTAssertEqual(message.attachmentsForForwarding.count, 1)
    }

    func testRepeatedSourceIdentityPrefersTheDownloadedCopy() {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let message = MessageBuilder().withId("downloaded-source-forward").build(in: context)
        _ = AttachmentBuilder().withId("local_repeated-source").queued()
            .forMessage(message).build(in: context)
        let downloaded = AttachmentBuilder().withId("local_repeated-source").downloaded()
            .withLocalURL("Attachments/downloaded-source.pdf")
            .forMessage(message).build(in: context)
        XCTAssertEqual(message.attachmentsForForwarding.map(\.objectID), [downloaded.objectID])
    }
}
