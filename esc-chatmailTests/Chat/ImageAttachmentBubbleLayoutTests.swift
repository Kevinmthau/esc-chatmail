import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// Exercises the production image layout with an unbounded vertical proposal, as a chat
/// row receives, and with the thumbnail arriving after a lazy transcript is positioned.
/// Image-state fixtures cover layout rather than download scheduling, finger momentum,
/// or pagination. One real bubble also verifies a download's metadata update stays stable.
@MainActor
final class ImageAttachmentBubbleLayoutTests: XCTestCase {
    func testStandardSize_preservesAspectRatioWithinWidthAndHeightBounds() {
        for maxWidth: CGFloat in [200, 280, 600] {
            let portrait = layoutSize(width: 600, height: 1_000, maxWidth: maxWidth)
            XCTAssertLessThanOrEqual(portrait.width, maxWidth)
            XCTAssertLessThanOrEqual(portrait.height, 420)
            XCTAssertEqual(portrait.width / portrait.height, 0.6, accuracy: 0.0001)

            let landscape = layoutSize(width: 4_000, height: 200, maxWidth: maxWidth)
            assertSize(landscape, equals: CGSize(width: maxWidth, height: maxWidth / 20))
        }

        assertSize(
            layoutSize(width: 600, height: 1_000, maxWidth: 280),
            equals: CGSize(width: 252, height: 420)
        )
        assertSize(
            layoutSize(width: 100, height: 10_000, maxWidth: 280),
            equals: CGSize(width: 4.2, height: 420)
        )
    }

    func testCompactSize_includesPaddingAndRetainsNativeSizeLimit() {
        assertSize(
            layoutSize(width: 600, height: 300, maxWidth: 280, presentation: .compact),
            equals: CGSize(width: 280, height: 148)
        )
        assertSize(
            layoutSize(width: 120, height: 60, maxWidth: 600, presentation: .compact),
            equals: CGSize(width: 76, height: 46)
        )
        assertSize(
            layoutSize(width: 600, height: 1_000, maxWidth: 280, presentation: .compact),
            equals: CGSize(width: 112, height: 176)
        )
    }

    func testMissingOrInvalidDimensions_useFiniteBoundedPlaceholder() {
        let invalidDimensions: [CGSize] = [
            .zero,
            CGSize(width: 0, height: 100),
            CGSize(width: 100, height: 0),
            CGSize(width: -20, height: 100),
            CGSize(width: 100, height: -20),
            CGSize(width: CGFloat.nan, height: 100),
            CGSize(width: 100, height: CGFloat.infinity)
        ]

        for dimensions in invalidDimensions {
            for maxWidth: CGFloat in [120, 200, 280, 600] {
                let size = layoutSize(
                    width: dimensions.width,
                    height: dimensions.height,
                    maxWidth: maxWidth
                )
                let width = min(200, maxWidth)
                assertSize(size, equals: CGSize(width: width, height: width * 0.75))
            }
        }
    }

    func testMountedContent_loadingLoadedAndFailed_keepReservedSize() throws {
        let images = [
            makeImage(size: CGSize(width: 120, height: 10)),
            makeImage(size: CGSize(width: 10, height: 120)),
            makeImage(size: CGSize(width: 1, height: 1))
        ]

        for presentation: InlineImagePresentationPolicy in [.standard, .compact] {
            for maxWidth: CGFloat in [200, 280, 600] {
                let size = layoutSize(
                    width: 600,
                    height: 1_000,
                    maxWidth: maxWidth,
                    presentation: presentation
                )
                let host = try mountInTestWindow(content(size: size, presentation: presentation))
                assertSize(measuredSize(of: host, width: maxWidth), equals: size)

                for image in images {
                    host.rootView = content(image: image, size: size, presentation: presentation)
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    assertSize(measuredSize(of: host, width: maxWidth), equals: size)
                }

                host.rootView = content(isLoading: false, size: size, presentation: presentation)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                assertSize(measuredSize(of: host, width: maxWidth), equals: size)
            }
        }
    }

    func testMountedContent_widthChangeAndWarmReentry_useTheSameLayout() throws {
        let image = makeImage(size: CGSize(width: 10, height: 120))
        let firstSize = layoutSize(width: 800, height: 600, maxWidth: 200)
        let host = try mountInTestWindow(content(size: firstSize))

        for width: CGFloat in [200, 280, 600, 200] {
            let size = layoutSize(width: 800, height: 600, maxWidth: width)
            host.rootView = content(image: image, size: size)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            assertSize(measuredSize(of: host, width: width), equals: size)

            let warmHost = try mountInTestWindow(content(image: image, size: size))
            assertSize(measuredSize(of: warmHost, width: width), equals: size)
        }
    }

    func testMountedBubble_downloadedDimensions_doNotReplaceReservedPlaceholderSize() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        // Uploading with no preview path starts neither a thumbnail read nor a download.
        let attachment = AttachmentBuilder()
            .asImage(width: 0, height: 0)
            .downloading()
            .build(in: context)
        let apiClient = MockGmailAPIClient()
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            prepareDownloadDirectories: {}
        )
        let host = try mountInTestWindow(
            ImageAttachmentBubble(attachment: attachment, downloader: downloader, onTap: {})
        )
        let proposal = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        let original = host.sizeThatFits(in: proposal)
        assertSize(original, equals: CGSize(width: 200, height: 150))

        attachment.width = 2_400
        attachment.height = 3_200
        host.rootView = ImageAttachmentBubble(
            attachment: attachment,
            downloader: downloader,
            onTap: {}
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        assertSize(host.sizeThatFits(in: proposal), equals: original)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 0)
    }

    func testDelayedThumbnailInLazyStack_keepsVisibleMarkerAtSamePosition() async throws {
        let state = TranscriptState()
        let observation = TranscriptObservation()
        let host = try mountInTestWindow(
            TranscriptFixture(state: state, observation: observation)
        )
        await waitUntil { observation.didMount }
        state.scrollToMarker = true
        await waitUntil { abs(observation.markerFrame.midY - 260) < 1 }
        await settleLayout(of: host)
        let before = observation.markerFrame
        XCTAssertGreaterThan(before.minY, 0)
        XCTAssertLessThan(before.maxY, 520)

        // Arrives in a later turn, while the already-visible marker is being read. The
        // image's very different ratio must not change the attachment's reserved frame.
        try? await Task.sleep(nanoseconds: 30_000_000)
        state.image = makeImage(size: CGSize(width: 10, height: 120))
        await waitUntil { observation.didRenderImage }
        await settleLayout(of: host)

        XCTAssertEqual(observation.markerFrame.minY, before.minY, accuracy: 0.5)
        XCTAssertEqual(observation.markerFrame.height, before.height, accuracy: 0.5)
    }

    func testMountedBubble_analysisAndFailurePolicyChanges_keepReservedGeometry() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let attachment = AttachmentBuilder()
            .asImage(width: 300, height: 300)
            .downloading()
            .build(in: context)
        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(), prepareDownloadDirectories: {}
        )
        let proposal = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)

        for initial: InlineImagePresentationPolicy in [.standard, .compact] {
            let host = try mountInTestWindow(ImageAttachmentBubble(
                attachment: attachment, downloader: downloader, presentation: initial, onTap: {}
            ))
            let original = host.sizeThatFits(in: proposal)
            let updated: InlineImagePresentationPolicy = initial == .standard ? .compact : .standard
            host.rootView = ImageAttachmentBubble(
                attachment: attachment, downloader: downloader,
                presentation: updated, onTap: {}
            )
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            assertSize(host.sizeThatFits(in: proposal), equals: original)

            let remounted = try mountInTestWindow(ImageAttachmentBubble(
                attachment: attachment, downloader: downloader, presentation: updated, onTap: {}
            ))
            XCTAssertNotEqual(remounted.sizeThatFits(in: proposal).height, original.height)
        }
    }

    // MARK: - Helpers

    private func layoutSize(
        width: CGFloat,
        height: CGFloat,
        maxWidth: CGFloat,
        presentation: InlineImagePresentationPolicy = .standard
    ) -> CGSize {
        ImageAttachmentLayout.size(
            pixelWidth: width,
            pixelHeight: height,
            maxWidth: maxWidth,
            displayScale: 2,
            presentation: presentation
        )
    }

    private func content(
        image: UIImage? = nil,
        isLoading: Bool = true,
        size: CGSize,
        presentation: InlineImagePresentationPolicy = .standard
    ) -> ImageAttachmentBubbleContent {
        ImageAttachmentBubbleContent(
            image: image,
            isLoading: image == nil && isLoading,
            filename: "A photo with a long filename that must not resize the attachment.jpg",
            presentation: presentation,
            size: size
        )
    }

    private func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func measuredSize(
        of host: UIHostingController<ImageAttachmentBubbleContent>,
        width: CGFloat
    ) -> CGSize {
        host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func assertSize(
        _ actual: CGSize,
        equals expected: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(actual.width.isFinite && actual.height.isFinite, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
    }

    private func settleLayout<Content: View>(of host: UIHostingController<Content>) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for hosted transcript layout", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private final class TranscriptState: ObservableObject {
        @Published var image: UIImage?
        @Published var scrollToMarker = false
    }

    private final class TranscriptObservation {
        var markerFrame = CGRect.null
        var didMount = false
        var didRenderImage = false
    }

    private struct MarkerFramePreference: PreferenceKey {
        static let defaultValue = CGRect.null

        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if !next.isNull { value = next }
        }
    }

    private struct TranscriptFixture: View {
        @ObservedObject var state: TranscriptState
        let observation: TranscriptObservation

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 600)
                        ImageAttachmentBubbleContent(
                            image: state.image,
                            isLoading: state.image == nil,
                            filename: "photo.jpg",
                            presentation: .standard,
                            size: CGSize(width: 240, height: 180)
                        )
                        Text("The message being read")
                            .frame(height: 40)
                            .id("marker")
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MarkerFramePreference.self,
                                        value: geometry.frame(in: .named("transcript"))
                                    )
                                }
                            }
                        Color.clear.frame(height: 600)
                    }
                }
                .coordinateSpace(name: "transcript")
                .defaultScrollAnchor(.top)
                .onAppear { observation.didMount = true }
                .onPreferenceChange(MarkerFramePreference.self) { observation.markerFrame = $0 }
                .onChange(of: state.scrollToMarker) { _, shouldScroll in
                    if shouldScroll { proxy.scrollTo("marker", anchor: .center) }
                }
                .onChange(of: state.image != nil) { _, hasImage in
                    observation.didRenderImage = hasImage
                }
            }
            .frame(width: 320, height: 520)
        }
    }
}
