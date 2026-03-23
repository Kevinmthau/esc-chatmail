import XCTest
@testable import esc_chatmail

final class HTMLRemoteImageAttachmentFallbackTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII=")!

    func testInlineAttachmentStyleImages_rewritesSalesforceStyleAttachmentImage() async throws {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let headers: [String: String] = [
                "Content-Type": "image/png",
                "Content-Disposition": "attachment; filename=\"Brambles_Banner.png\"",
                "Content-Length": "\(imageData.count)"
            ]

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )
            )

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let html = """
        <html><body><img src="https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO"></body></html>
        """

        let result = await service.inlineAttachmentStyleImages(
            in: html,
            senderEmail: "thomas@brambles.golf"
        )

        XCTAssertTrue(result.contains("src=\"data:image/png;base64,"))
        XCTAssertFalse(result.contains("https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://brambles.golf/", "https://brambles.golf/"])
    }

    func testInlineAttachmentStyleImages_leavesNormalFileExtensionImagesUntouched() async {
        let service = HTMLRemoteImageAttachmentFallback { _ in
            XCTFail("Normal image URLs should not be probed by the fallback")
            return (
                Data(),
                HTTPURLResponse(url: URL(string: "https://example.com/banner.jpg")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let html = #"<img src="https://example.com/banner.jpg" alt="banner">"#
        let result = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertEqual(result, html)
    }

    func testInlineAttachmentStyleImages_doesNotRewriteInlineResponses() async throws {
        let recorder = RequestRecorder()
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/png",
                        "Content-Disposition": "inline; filename=\"banner.png\""
                    ]
                )
            )

            return (Data(), response)
        }

        let html = #"<img src="https://cdn.example.com/assets/banner?variant=1">"#
        let result = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertEqual(result, html)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD"])
    }
}

private actor RequestRecorder {
    private(set) var methods: [String] = []
    private(set) var referers: [String?] = []

    func record(_ request: URLRequest) {
        methods.append(request.httpMethod ?? "")
        referers.append(request.value(forHTTPHeaderField: "Referer"))
    }

    func snapshot() -> (methods: [String], referers: [String?]) {
        (methods, referers)
    }
}
