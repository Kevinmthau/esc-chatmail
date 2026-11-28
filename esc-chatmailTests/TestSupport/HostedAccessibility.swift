#if os(iOS)
import UIKit
import XCTest

/// Reads the accessibility tree SwiftUI and UIKit build for a view mounted in the unit-test
/// host, so a test can assert what VoiceOver and Voice Control are given: each element's label,
/// value, hint, traits, custom actions and input labels, and what activating it does.
///
/// SwiftUI builds a view's accessibility elements only while the app's accessibility runtime is
/// on, which an assistive client such as VoiceOver turns on; in a test host nothing does, and a
/// mounted view has none. `enableHostedAccessibility()` turns it on: it loads the simulator
/// runtime's `usr/lib/libAccessibility.dylib` (under `IPHONE_SIMULATOR_ROOT`) and calls its
/// `_AXSApplicationAccessibilitySetEnabled`, as a review of the accessibility line measured on
/// the iOS 27.0 simulator (2026-11-28). It sets the switch back off at the test's teardown, but
/// that does not undo it: once on, SwiftUI kept building elements for views mounted later in the
/// process (measured the same day), so a later test in the same host may see a tree it did not
/// ask for. Nothing reads one unasked today, so no test may assert that a tree is empty.
///
/// HONEST SCOPE: `_AXSApplicationAccessibilitySetEnabled` is private SPI, used in tests only, as
/// `SQLiteQueryPlanRecorder` uses Core Data's. What this reads is the tree an assistive client is
/// handed; nothing is spoken, and VoiceOver's own navigation (its focus order, its rotors, the
/// More Content rotor) is not exercised. `HostedAccessibilityRuntimeTests` (default plan) fails
/// if the runtime stops building elements, so a test written on this helper cannot pass by
/// reading an empty tree unnoticed.
@MainActor
enum HostedAccessibility {
    enum Failure: Error, CustomStringConvertible {
        case libraryNotLoaded(String)
        case symbolMissing

        var description: String {
            switch self {
            case .libraryNotLoaded(let path):
                return "Could not load \(path): \(String(cString: dlerror()))"
            case .symbolMissing:
                return "libAccessibility has no _AXSApplicationAccessibilitySetEnabled"
            }
        }
    }

    private typealias SetEnabled = @convention(c) (Int32) -> Void

    static func setRuntimeEnabled(_ isEnabled: Bool) throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let path = root + "/usr/lib/libAccessibility.dylib"
        guard let handle = dlopen(path, RTLD_NOW) else {
            throw Failure.libraryNotLoaded(path)
        }
        guard let symbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled") else {
            throw Failure.symbolMissing
        }
        unsafeBitCast(symbol, to: SetEnabled.self)(isEnabled ? 1 : 0)
    }

    /// The elements under `root`, in the order the tree gives them, skipping what is hidden.
    static func elements(in root: NSObject) -> [HostedAccessibilityElement] {
        var nodes: [NSObject] = []
        collect(root, into: &nodes, depth: 0)
        return nodes.map(HostedAccessibilityElement.init(object:))
    }

    private static func collect(_ object: NSObject, into nodes: inout [NSObject], depth: Int) {
        guard depth < 100, !object.accessibilityElementsHidden else { return }
        if object.isAccessibilityElement {
            nodes.append(object)
            return
        }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements {
            children = elements.compactMap { $0 as? NSObject }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if children.isEmpty, let view = object as? UIView {
            children = view.subviews
        }
        for child in children {
            collect(child, into: &nodes, depth: depth + 1)
        }
    }
}

/// One element of a hosted accessibility tree (`HostedAccessibility`).
@MainActor
struct HostedAccessibilityElement {
    let object: NSObject

    var label: String { object.accessibilityLabel ?? "" }
    var value: String { object.accessibilityValue ?? "" }
    var hint: String { object.accessibilityHint ?? "" }
    var traits: UIAccessibilityTraits { object.accessibilityTraits }
    var customActionNames: [String] { (object.accessibilityCustomActions ?? []).map(\.name) }
    var inputLabels: [String] { object.accessibilityUserInputLabels ?? [] }

    /// What a double-tap does: `accessibilityActivate()`.
    @discardableResult
    func activate() -> Bool {
        object.accessibilityActivate()
    }

    /// Runs the custom action named `name`, as the Actions rotor would; false if there is none.
    @discardableResult
    func performCustomAction(named name: String) -> Bool {
        guard let action = object.accessibilityCustomActions?.first(where: { $0.name == name }) else {
            return false
        }
        if let handler = action.actionHandler {
            return handler(action)
        }
        guard let target = action.target as? NSObject else { return false }
        return target.perform(action.selector, with: action) != nil
    }

    var description: String {
        "label=\"\(label)\" value=\"\(value)\" hint=\"\(hint)\" traits=\(traits.rawValue) actions=\(customActionNames) input=\(inputLabels)"
    }
}

extension XCTestCase {
    /// Turns the test host's accessibility runtime on for this test and off at its teardown
    /// (`HostedAccessibility`).
    @MainActor
    func enableHostedAccessibility() throws {
        try HostedAccessibility.setRuntimeEnabled(true)
        addTeardownBlock { @MainActor in
            try? HostedAccessibility.setRuntimeEnabled(false)
        }
    }

    /// The elements under `root` once `condition` holds of them, polled until `timeout`:
    /// SwiftUI builds its elements over a few run-loop turns after a mount or a change.
    @MainActor
    func hostedAccessibilityElements(
        in root: NSObject,
        timeout: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: ([HostedAccessibilityElement]) -> Bool
    ) async -> [HostedAccessibilityElement] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            (root as? UIView)?.layoutIfNeeded()
            let elements = HostedAccessibility.elements(in: root)
            if condition(elements) {
                return elements
            }
            guard Date() < deadline else {
                XCTFail(
                    "The accessibility tree never matched; it held:\n"
                        + elements.map(\.description).joined(separator: "\n"),
                    file: file,
                    line: line
                )
                return elements
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
#endif
