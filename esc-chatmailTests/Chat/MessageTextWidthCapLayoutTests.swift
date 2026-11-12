import SwiftUI
import XCTest
@testable import esc_chatmail

/// Lays out `MessageTextWidthCap` in a column shaped like the Mac row's where an image is
/// wider than the text's share: 400 points wide, with a 338-point cap (a 520-point chat
/// column).
///
/// HONEST SCOPE: this is the modifier in a stand-in column, not `MessageBubble`. That the
/// row's text and subject carry the modifier is `ChatBubbleStyleSourceTests`' to pin, from
/// source, and none of it has been seen in the app.
@MainActor
final class MessageTextWidthCapLayoutTests: XCTestCase {
    private static let columnWidth: CGFloat = 400
    private static let cap: CGFloat = 338
    private static let longText = String(repeating: "A row of words that wraps. ", count: 12)

    /// Revert-check: a frame in `MessageTextWidthCap.body` wider than the cap
    /// (`maxWidth + 1000`) makes this fail: the text then wraps at the column's 400 points.
    func testLongText_wrapsAtTheCapNotAtTheColumnsWidth() throws {
        for isFromMe in [false, true] {
            let capped = try textFrame(Self.longText, cap: Self.cap, isFromMe: isFromMe)
            XCTAssertLessThanOrEqual(capped.width, Self.cap + 0.01)
            XCTAssertGreaterThan(capped.width, Self.cap - 80)

            let uncapped = try textFrame(Self.longText, cap: nil, isFromMe: isFromMe)
            XCTAssertGreaterThan(uncapped.width, Self.cap)
        }
    }

    /// The cap's frame is wider than a short text, and the text keeps to the row's own side
    /// of it, which is the column's edge.
    ///
    /// Revert-check: dropping `alignment:` from the frame in `MessageTextWidthCap.body` makes
    /// this fail: the text is then centered in the frame, off both edges.
    func testShortText_keepsToTheRowsSideOfTheColumn() throws {
        let incoming = try textFrame("Hi", cap: Self.cap, isFromMe: false)
        XCTAssertEqual(incoming.minX, 0, accuracy: 0.01)
        XCTAssertLessThan(incoming.width, 60)

        let outgoing = try textFrame("Hi", cap: Self.cap, isFromMe: true)
        XCTAssertEqual(outgoing.maxX, Self.columnWidth, accuracy: 0.01)
        XCTAssertLessThan(outgoing.width, 60)
    }

    /// A row with no subject, or with attachments and no text, hands the modifier content
    /// that draws nothing. A frame there would be one more line in the row's stack: its
    /// spacing, in every such row.
    ///
    /// Revert-check: framing `VStack { content }` in `MessageTextWidthCap.body` (anything that
    /// makes a view where the content makes none) makes this fail, 28 for 24.
    func testContentThatDrawsNothing_addsNoLineToTheStack() throws {
        for cap: CGFloat? in [Self.cap, nil] {
            let host = try mountInTestWindow(
                VStack(spacing: 4) {
                    Color.clear.frame(width: 10, height: 10)
                    EmptyView()
                        .modifier(MessageTextWidthCap(maxWidth: cap, isFromMe: false))
                    Color.clear.frame(width: 10, height: 10)
                }
            )

            let size = host.sizeThatFits(in: CGSize(width: Self.columnWidth, height: 1_000))
            XCTAssertEqual(size.height, 24, accuracy: 0.01)
        }
    }

    // MARK: - Helpers

    /// The frame of a text in the column's coordinate space, as it was last laid out.
    private func textFrame(_ text: String, cap: CGFloat?, isFromMe: Bool) throws -> CGRect {
        let probe = FrameProbe()
        let host = try mountInTestWindow(
            Column(text: text, cap: cap, isFromMe: isFromMe, probe: probe)
        )
        _ = host.sizeThatFits(in: CGSize(width: Self.columnWidth, height: 1_000))
        return try XCTUnwrap(probe.frame, "The text was never laid out")
    }

    private final class FrameProbe {
        var frame: CGRect?
    }

    private struct Column: View {
        let text: String
        let cap: CGFloat?
        let isFromMe: Bool
        let probe: FrameProbe

        var body: some View {
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .background {
                        GeometryReader { geometry in
                            Self.record(geometry.frame(in: .named("column")), in: probe)
                        }
                    }
                    .modifier(MessageTextWidthCap(maxWidth: cap, isFromMe: isFromMe))
            }
            .frame(width: MessageTextWidthCapLayoutTests.columnWidth, alignment: isFromMe ? .trailing : .leading)
            .coordinateSpace(name: "column")
        }

        private static func record(_ frame: CGRect, in probe: FrameProbe) -> Color {
            probe.frame = frame
            return Color.clear
        }
    }
}
