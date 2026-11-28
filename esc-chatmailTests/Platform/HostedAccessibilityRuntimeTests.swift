#if os(iOS)
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The canary for `HostedAccessibility`: with the test host's accessibility runtime switched on,
/// SwiftUI builds elements for a mounted view. If a simulator runtime moves or drops the private
/// switch, or SwiftUI stops building elements under it, this fails, rather than every test
/// written on the helper reading an empty tree.
@MainActor
final class HostedAccessibilityRuntimeTests: XCTestCase {
    /// Revert-check: deleting the `enableHostedAccessibility()` call fails this (no element).
    func testRuntimeOn_aMountedButton_isOneNamedButtonElementThatActivatesOnce() async throws {
        try enableHostedAccessibility()
        var presses = 0
        let host = try mountInTestWindow(
            Button("Canary") { presses += 1 }
                .padding()
        )

        let elements = await hostedAccessibilityElements(in: host.view) { elements in
            elements.contains { $0.label == "Canary" }
        }
        let button = try XCTUnwrap(elements.first { $0.label == "Canary" })

        XCTAssertTrue(button.traits.contains(.button), button.description)
        XCTAssertTrue(button.activate())
        XCTAssertEqual(presses, 1)
    }
}
#endif
