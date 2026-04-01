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

        XCTAssertTrue(result.contains("src=\"data:image/"))
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

    func testInlineAttachmentStyleImages_rewritesInlineModernFormatImagesToSafeDataURL() async throws {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/webp",
                        "Content-Disposition": "inline; filename=\"hero.webp\"",
                        "Content-Length": "\(imageData.count)"
                    ]
                )
            )

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let html = #"<img src="https://cdn.example.com/banner.jpg?format=webp&width=600">"#
        let result = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertTrue(result.contains("src=\"data:image/"))
        XCTAssertFalse(result.contains("format=webp"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://example.com/", "https://example.com/"])
        XCTAssertEqual(snapshot.accepts, [
            "image/png,image/jpeg,image/gif,image/bmp,image/*;q=0.8,*/*;q=0.5",
            "image/png,image/jpeg,image/gif,image/bmp,image/*;q=0.8,*/*;q=0.5"
        ])
    }

    func testInlineAttachmentStyleImages_doesNotNegativeCacheTransientFailures() async {
        let recorder = RequestRecorder()
        let attempts = AttemptCounter()
        let imageData = onePixelPNG

        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let requestKey = "\(request.httpMethod ?? "GET")|\(request.url?.absoluteString ?? "")"
            let attempt = await attempts.increment(for: requestKey)
            if request.httpMethod == "HEAD", attempt == 1 {
                throw URLError(.timedOut)
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://cdn.example.com/open.php?id=hero")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Content-Disposition": "attachment; filename=\"hero.png\"",
                    "Content-Length": "\(imageData.count)"
                ]
            )!

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let html = #"<img src="https://cdn.example.com/open.php?id=hero">"#

        let first = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")
        XCTAssertEqual(first, html)

        let second = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")
        XCTAssertTrue(second.contains("src=\"data:image/"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "HEAD", "GET"])
    }

    func testInlineAttachmentStyleImages_boundsPositiveDataURLCache() async {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback(
            requestExecutor: { request in
                await recorder.record(request)

                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://cdn.example.com/open.php?id=fallback")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/png",
                        "Content-Disposition": "attachment; filename=\"hero.png\"",
                        "Content-Length": "\(imageData.count)"
                    ]
                )!

                if request.httpMethod == "HEAD" {
                    return (Data(), response)
                }

                return (imageData, response)
            },
            rewrittenDataURLCacheMaxEntries: 1,
            rewrittenDataURLCacheMaxBytes: 1024
        )

        let firstHTML = #"<img src="https://cdn.example.com/open.php?id=first">"#
        let secondHTML = #"<img src="https://cdn.example.com/open.php?id=second">"#

        _ = await service.inlineAttachmentStyleImages(in: firstHTML, senderEmail: "sender@example.com")
        _ = await service.inlineAttachmentStyleImages(in: secondHTML, senderEmail: "sender@example.com")
        _ = await service.inlineAttachmentStyleImages(in: firstHTML, senderEmail: "sender@example.com")

        let snapshot = await recorder.snapshot()
        let firstURLRequests = zip(snapshot.urls, snapshot.methods).filter { url, _ in
            url.contains("id=first")
        }.map { $0.1 }

        XCTAssertEqual(firstURLRequests, ["HEAD", "GET", "HEAD", "GET"])
    }
}

private actor RequestRecorder {
    private(set) var methods: [String] = []
    private(set) var referers: [String?] = []
    private(set) var accepts: [String?] = []
    private(set) var urls: [String] = []

    func record(_ request: URLRequest) {
        methods.append(request.httpMethod ?? "")
        referers.append(request.value(forHTTPHeaderField: "Referer"))
        accepts.append(request.value(forHTTPHeaderField: "Accept"))
        urls.append(request.url?.absoluteString ?? "")
    }

    func snapshot() -> (methods: [String], referers: [String?], accepts: [String?], urls: [String]) {
        (methods, referers, accepts, urls)
    }
}

private actor AttemptCounter {
    private var attempts: [String: Int] = [:]

    func increment(for key: String) -> Int {
        let nextValue = (attempts[key] ?? 0) + 1
        attempts[key] = nextValue
        return nextValue
    }
}
