#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import esc_chatmail

/// What the Mac chat header's name bar adds to the top of the view it is put on
/// (`MacChatHeaderNameBar`, `View.macChatHeaderNameBar`). Mac only, so it runs in
/// `Mac.xctestplan`.
///
/// The bar is part of the transcript's top inset. That inset has to be one number for every
/// chat and must not change after the chat mounts, because the transcript's hidden anchor pass
/// measures its viewport (`ChatMessagesCoordinator`). So the bar is 30 points tall whatever the
/// name is, and the modifier insets by the bar's height and nothing else.
///
/// HONEST SCOPE: the views are laid out, and in one test drawn, in a hosting view in a window
/// that is never shown. That measures the bar and the inset SwiftUI derives from it. It does
/// not show the bar under a real toolbar, over a real transcript, or the capsule's glass, which
/// an off-screen drawing leaves out; none of that has been seen in the app
/// (`docs/mac-imessage-ui-plan.md`, "PR 3 as built"). The drawing test pins what an off-screen
/// drawing does on the macOS it runs on. Whether the app would lose its transcript under a
/// capsule that reaches the column's edges is not known.
@MainActor
final class MacChatHeaderNameBarLayoutTests: XCTestCase {
    /// Revert-check: deleting `.frame(height: metrics.nameBarHeight)` from
    /// `MacChatHeaderNameBar.body` makes this fail: the bar would be as tall as its capsule.
    func testBar_isTheMetricsHeight_whateverTheNameAndWhetherItOpensParticipants() {
        let names = ["A", "Ada Lovelace", String(repeating: "A very long conversation name ", count: 20)]

        for name in names {
            for opensParticipants in [true, false] {
                let host = NSHostingView(
                    rootView: MacChatHeaderNameBar(
                        metrics: .mac,
                        name: name,
                        opensParticipants: opensParticipants,
                        onOpenParticipants: {}
                    )
                )

                XCTAssertEqual(
                    host.fittingSize.height,
                    ChatHeaderMetrics.mac.nameBarHeight,
                    accuracy: 0.01,
                    "name of \(name.count) characters, opensParticipants: \(opensParticipants)"
                )
            }
        }
    }

    /// The transcript's top inset under the header is the bar's 30 points, exactly.
    ///
    /// Revert-check: changing `spacing: 0` to `spacing: 8` in the `safeAreaBar` call in
    /// `MacChatHeaderNameBarModifier.body` makes this fail.
    ///
    /// HONEST SCOPE: deleting `spacing: 0` does not fail it. On macOS 27.2 a `safeAreaBar` given
    /// no spacing added none. The modifier still says 0, so the inset does not depend on a
    /// default.
    func testModifier_insetsTheContentByTheBarsHeightAndNothingElse() async {
        let inset = await measuredTopInset(metrics: .mac)

        XCTAssertEqual(inset ?? -1, ChatHeaderMetrics.mac.nameBarHeight, accuracy: 0.01)
    }

    /// A chat whose header style has no name bar gets no inset.
    ///
    /// Revert-check: replacing `if let metrics` in `MacChatHeaderNameBarModifier.body` with an
    /// unconditional bar at `ChatHeaderMetrics.mac` makes this fail.
    func testModifier_noMetrics_addsNoInset() async {
        let inset = await measuredTopInset(metrics: nil)

        XCTAssertEqual(inset ?? -1, 0, accuracy: 0.01)
    }

    /// A name too long for the chat column truncates well short of the column's edges, and the
    /// transcript under the bar still draws.
    ///
    /// Drawn off screen, a glass capsule that came within 20 points of both edges of the scroll
    /// view it sits over took that scroll view's whole content out of the drawing, at every
    /// width tried; from 22 points the content drew. The layout was the same either way. The
    /// bar's padding keeps the capsule 48 points in (`ChatHeaderMetrics.nameBarHorizontalPadding`).
    ///
    /// Revert-check: setting `nameBarHorizontalPadding` to 16 in `ChatHeaderMetrics.mac` makes
    /// this fail: the transcript is in the first drawing and gone from the ones after it.
    func testBar_nameTooLongForTheColumn_theTranscriptUnderItStillDraws() async throws {
        let transcriptColor = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        let root = ScrollView {
            Color(nsColor: transcriptColor).frame(height: 600)
        }
        .macChatHeaderNameBar(
            metrics: .mac,
            name: String(repeating: "A very long conversation name ", count: 20),
            opensParticipants: true,
            onOpenParticipants: {}
        )
        let size = NSSize(width: 520, height: 320)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // The middle of the transcript, well below the bar, drawn fifteen times a tenth of a
        // second apart: the transcript was in the first drawings and left them a moment after
        // the view mounted, so one sample taken at once proves nothing. A count of drawings,
        // not a stretch of time: on a busy machine each takes longer and all are still made.
        let sampleCount = 15
        var samples: [NSColor] = []
        for _ in 0..<sampleCount {
            if let color = Self.color(in: host, at: NSPoint(x: size.width / 2, y: size.height / 2)) {
                samples.append(color)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        window.contentView = nil

        // A machine that cannot draw off screen at all says nothing about the bar.
        try XCTSkipIf(samples.isEmpty, "The view could not be drawn off screen on this machine")
        // One drawing that could not be made is not the bar's fault. Most of them must be
        // there, because the transcript left after the first: two thirds leaves at least nine
        // drawings made after the view mounted.
        XCTAssertGreaterThanOrEqual(samples.count, sampleCount * 2 / 3, "Too few drawings could be made")
        let missing = samples.filter { $0.blueComponent < 0.9 || $0.redComponent > 0.1 }
        XCTAssertTrue(
            missing.isEmpty,
            "The transcript is missing from \(missing.count) of \(samples.count) drawings: \(missing.first.map(String.init(describing:)) ?? "")"
        )
    }

    // MARK: - Measuring

    /// The color the view draws at a point, from a drawing of it made off screen.
    private static func color(in view: NSView, at point: NSPoint) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        // The bitmap's rows run from the top; a hosting view's coordinates are flipped to match.
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
            .usingColorSpace(.deviceRGB)
    }

    /// The top safe-area inset of a view the name bar is put on, as that view's own content
    /// reads it, in a 480 by 320 window that is never shown.
    private func measuredTopInset(metrics: ChatHeaderMetrics?) async -> CGFloat? {
        let measurement = InsetMeasurement()
        let root = GeometryReader { proxy in
            Color.clear.preference(key: TopInsetKey.self, value: proxy.safeAreaInsets.top)
        }
        .onPreferenceChange(TopInsetKey.self) { measurement.topInset = $0 }
        .macChatHeaderNameBar(
            metrics: metrics,
            name: "Ada Lovelace",
            opensParticipants: true,
            onOpenParticipants: {}
        )

        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        await waitUntil { measurement.topInset != nil }
        window.contentView = nil
        return measurement.topInset
    }

    /// Polls `condition` until it holds or `timeout` elapses, without failing: the caller
    /// asserts on what was measured.
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

/// The inset SwiftUI reports, written from its preference callback, which is `@Sendable`, and
/// read by the test on the main actor.
///
/// `@unchecked Sendable`: every access to `value` is made under `lock`.
private final class InsetMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CGFloat?

    var topInset: CGFloat? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct TopInsetKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
#endif
