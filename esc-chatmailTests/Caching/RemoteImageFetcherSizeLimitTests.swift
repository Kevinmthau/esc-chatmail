import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// The limits `RemoteImageFetcher` puts on a sender's image: on its bytes while they arrive,
/// and on its pixels before any are decoded (architecture review 2026-11,
/// `security-privacy#1`). ImageIO fixtures only, so the suite builds for the Mac too.
final class RemoteImageFetcherSizeLimitTests: XCTestCase {
    private var session: URLSession!
    private var urls: [URL] = []

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StreamingStubURLProtocol.removeScripts(for: urls)
        urls = []
        super.tearDown()
    }

    // MARK: - Bytes

    /// The stub sends the body's first bytes and never ends its load, so the error can only
    /// come from the response's headers.
    ///
    /// Revert-check: `SSRFGuardingURLSession.boundedData` in `RemoteImageFetcher.imageData`.
    /// `session.data(for:)` there waits for the whole body until the request times out.
    func testImageData_declaredLengthPastTheLimit_isRefusedOnTheHeaders() async {
        let url = scripted(.init(
            headers: ["Content-Type": "image/png", "Content-Length": "5000"],
            chunks: [Data(repeating: 1, count: StreamingStubURLProtocol.sniffedByteCount)],
            finishes: false
        ))
        let fetcher = makeFetcher(maxImageBytes: 1_024)

        await assertImageData(of: fetcher, from: url, throws: .responseTooLarge(5_000))
    }

    /// With no declared length the limit is met while the body arrives, and the error names
    /// the limit.
    func testImageData_undeclaredBodyPastTheLimit_isGivenUpAtTheLimit() async {
        let url = scripted(.init(
            headers: ["Content-Type": "image/png"],
            chunks: Array(repeating: Data(repeating: 1, count: 512), count: 16)
        ))
        let fetcher = makeFetcher(maxImageBytes: 1_024)

        await assertImageData(of: fetcher, from: url, throws: .responseTooLarge(1_024))
    }

    /// A type that is not an image is refused on the headers too: the load here never ends.
    func testImageData_unsupportedContentType_isRefusedOnTheHeaders() async {
        let url = scripted(.init(
            headers: ["Content-Type": "text/html"],
            chunks: [Data("<html>".utf8)],
            finishes: false
        ))
        let fetcher = makeFetcher(maxImageBytes: 1_024)

        await assertImageData(of: fetcher, from: url, throws: .unsupportedContentType("text/html"))
    }

    func testImageData_bodyWithinTheLimit_isReturnedWhole() async throws {
        let chunks = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 200) }
        let url = scripted(.init(headers: ["Content-Type": "image/png"], chunks: chunks))
        let fetcher = makeFetcher(maxImageBytes: 1_024)

        let data = try await fetcher.imageData(from: url.absoluteString)

        XCTAssertEqual(data, chunks.reduce(Data(), +))
    }

    // MARK: - Pixels

    /// A valid PNG of more pixels than the budget allows is small on the wire (zeros
    /// compress) and is not decoded.
    ///
    /// Revert-check: `ImageDownsampler.decode` in `RemoteImageFetcher.decodedImage`.
    /// `PlatformImage(data:)` there returns an image for these bytes, of the size the header
    /// names.
    func testImage_imageOfMorePixelsThanTheBudget_isNotDecoded() async throws {
        let png = try TestImageData.zeroFilledGrayPNG(width: 8_200, height: 8_200)
        XCTAssertLessThan(png.count, 1_024 * 1_024, "premise: small on the wire")
        let url = scripted(.init(headers: ["Content-Type": "image/png"], chunks: [png]))

        let image = await makeFetcher().image(from: url.absoluteString)

        XCTAssertNil(image)
    }

    /// An image within the budget and past the cache's pixel cap comes back at the cap, so
    /// what the caches keep and re-encode is never the sender's full size.
    ///
    /// Revert-check: the same line. `PlatformImage(data:)` returns it 3,000 pixels wide.
    func testImage_imageWiderThanTheCacheCap_comesBackAtTheCap() async throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSizes: [CGSize(width: 3_000, height: 2_000)])
        let url = scripted(.init(headers: ["Content-Type": "image/jpeg"], chunks: [jpeg]))

        let fetched = await makeFetcher().image(from: url.absoluteString)

        let pixelSize = try XCTUnwrap(fetched).pixelSize
        XCTAssertEqual(
            max(pixelSize.width, pixelSize.height),
            ImageDownsampler.defaultMaxPixelDimension,
            accuracy: 1
        )
        XCTAssertEqual(pixelSize.width / pixelSize.height, 1.5, accuracy: 0.05)
    }

    // MARK: - Helpers

    private func makeFetcher(maxImageBytes: Int = 8 * 1_024 * 1_024) -> RemoteImageFetcher {
        RemoteImageFetcher(
            session: session,
            maxImageBytes: maxImageBytes,
            // A request the fetcher is still waiting on fails the test in seconds.
            timeoutInterval: 5,
            // Its own, so no other suite's flag turns remote images off here.
            remoteConfig: StaticRemoteConfigProvider()
        )
    }

    private func scripted(_ script: StreamingStubURLProtocol.Script) -> URL {
        let url = StreamingStubURLProtocol.uniqueURL()
        urls.append(url)
        StreamingStubURLProtocol.setScript(script, for: url)
        return url
    }

    private func assertImageData(
        of fetcher: RemoteImageFetcher,
        from url: URL,
        throws expected: RemoteImageFetchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let data = try await fetcher.imageData(from: url.absoluteString)
            XCTFail("Expected \(expected), got \(data.count) bytes", file: file, line: line)
        } catch let error as RemoteImageFetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
