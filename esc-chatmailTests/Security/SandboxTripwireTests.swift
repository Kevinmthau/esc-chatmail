import XCTest
@testable import esc_chatmail

/// Pins how the macOS sandbox tripwire is applied (docs/mac-app-plan.md, PR C).
///
/// `SandboxTripwire` itself is platform-neutral, so its tests run here with an
/// injected environment. The guarded call sites compile only for macOS, and
/// this target is iOS-only until PR F adds the Mac test plan, so their wiring
/// is pinned from the source text instead.
final class SandboxTripwireTests: XCTestCase {
    private let sandboxedEnvironment = [
        SandboxTripwirePolicy.containerIdentifierEnvironmentKey: "com.esc.inboxchat"
    ]
    private let unsandboxedEnvironment = ["HOME": "/Users/someone"]

    /// Each guarded function's first statement, exactly as written. A cleanup
    /// that throws must use the throwing form, so a refusal fails its caller
    /// instead of looking like a finished deletion: account removal would
    /// otherwise drop its durable reset marker with the files still there.
    private static let expectedGuardStatements: [SandboxTripwire.Operation: String] = [
        .freshInstallAttachmentFiles:
            "guard SandboxTripwire.permitsDestructiveCleanup(.freshInstallAttachmentFiles) else {",
        .accountRemovalAttachmentFiles:
            "try SandboxTripwire.ensureDestructiveCleanupPermitted(.accountRemovalAttachmentFiles)",
        .accountRemovalMessageBodies:
            "try SandboxTripwire.ensureDestructiveCleanupPermitted(.accountRemovalMessageBodies)",
        .orphanedMessageBodySweep:
            "guard SandboxTripwire.permitsDestructiveCleanup(.orphanedMessageBodySweep) else {",
        .orphanedAttachmentFileSweep:
            "guard SandboxTripwire.permitsDestructiveCleanup(.orphanedAttachmentFileSweep) else {"
    ]

    // Revert-check: fails if SandboxTripwire.ensureDestructiveCleanupPermitted(_:environment:)
    // returns instead of throwing on a refusal. Account removal propagates the
    // throw so its durable cleanup fails and keeps the reset marker; a silent
    // return would report the files deleted.
    func testEnsureDestructiveCleanupPermitted_outsideAppSandbox_throwsRefusalNamingOperation() {
        for operation in SandboxTripwire.Operation.allCases {
            XCTAssertThrowsError(
                try SandboxTripwire.ensureDestructiveCleanupPermitted(
                    operation,
                    environment: unsandboxedEnvironment
                ),
                "operation: \(operation.rawValue)"
            ) { error in
                XCTAssertEqual(error as? SandboxTripwireError, .refusedOutsideAppSandbox(operation))
            }
        }
    }

    // Revert-check: fails if ensureDestructiveCleanupPermitted(_:environment:)
    // refuses despite SandboxTripwirePolicy's .permitted verdict, which would
    // stop a correctly sandboxed Mac build from ever cleaning up.
    func testEnsureDestructiveCleanupPermitted_insideAppSandbox_returnsWithoutThrowing() {
        for operation in SandboxTripwire.Operation.allCases {
            XCTAssertNoThrow(
                try SandboxTripwire.ensureDestructiveCleanupPermitted(
                    operation,
                    environment: sandboxedEnvironment
                ),
                "operation: \(operation.rawValue)"
            )
        }
    }

    // Revert-check: fails if SandboxTripwire.permitsDestructiveCleanup(_:environment:)
    // stops following ensureDestructiveCleanupPermitted(_:environment:). The
    // non-throwing call sites return early only on false.
    func testPermitsDestructiveCleanup_eachEnvironment_followsPolicyVerdict() {
        for operation in SandboxTripwire.Operation.allCases {
            XCTAssertTrue(
                SandboxTripwire.permitsDestructiveCleanup(operation, environment: sandboxedEnvironment),
                "operation: \(operation.rawValue)"
            )
            XCTAssertFalse(
                SandboxTripwire.permitsDestructiveCleanup(operation, environment: unsandboxedEnvironment),
                "operation: \(operation.rawValue)"
            )
        }
    }

    // Revert-check: fails if any guard statement in expectedGuardStatements is
    // removed from FreshInstallHandler.clearAttachmentFiles,
    // AuthSession.deleteAttachmentFilesFromDisk,
    // HTMLContentHandler.deleteAllHTMLFromClosedAccount,
    // HTMLContentHandler.cleanupOrphanedFiles or
    // AttachmentDownloader.cleanupOrphanedFiles, moved below the function's
    // first statement, taken out of its `#if os(macOS)` branch, or switched to
    // the non-throwing form in a throwing cleanup.
    // HONEST SCOPE: this reads source text. It proves each guard is present,
    // first and compiled for macOS; it cannot prove the macOS branch runs.
    // The Mac test plan (PR F) is where these call sites first execute.
    func testMacOSCleanupCallSites_everyOperation_guardedFirstInItsNamedFunction() throws {
        XCTAssertEqual(
            Set(Self.expectedGuardStatements.keys),
            Set(SandboxTripwire.Operation.allCases),
            "A new tripwire operation must name the guard statement its call site uses"
        )

        let sources = try appSources()
        let guardLineCount = sources.reduce(0) { count, source in
            count + source.lines.filter {
                $0.contains("SandboxTripwire.ensureDestructiveCleanupPermitted(")
                    || $0.contains("SandboxTripwire.permitsDestructiveCleanup(")
            }.count
        }
        XCTAssertEqual(
            guardLineCount,
            Self.expectedGuardStatements.count,
            "Every tripwire call in the app must be one of the expected guard statements"
        )

        for operation in SandboxTripwire.Operation.allCases {
            guard let statement = Self.expectedGuardStatements[operation] else { continue }
            let nameParts = operation.rawValue.split(separator: ".").map(String.init)
            guard nameParts.count == 2 else {
                XCTFail("\(operation.rawValue) must be Type.function")
                continue
            }
            let typeName = nameParts[0]
            let functionName = nameParts[1]

            let matches = sources.flatMap { source in
                source.lines.indices
                    .filter { source.lines[$0] == statement }
                    .map { (source: source, index: $0) }
            }
            guard matches.count == 1, let match = matches.first else {
                XCTFail("\(operation.rawValue): expected exactly one `\(statement)`, found \(matches.count)")
                continue
            }
            let lines = match.source.lines
            let guardIndex = match.index

            XCTAssertTrue(
                match.source.fileName == "\(typeName).swift"
                    || match.source.fileName.hasPrefix("\(typeName)+"),
                "\(operation.rawValue): guard is in \(match.source.fileName)"
            )

            guard let functionIndex = lines[..<guardIndex].lastIndex(where: {
                !$0.hasPrefix("//") && $0.contains("func ")
            }) else {
                XCTFail("\(operation.rawValue): no function declaration above the guard")
                continue
            }
            XCTAssertTrue(
                lines[functionIndex].contains("func \(functionName)("),
                "\(operation.rawValue): guard is inside `\(lines[functionIndex])`"
            )

            guard let bodyIndex = lines[functionIndex..<guardIndex].firstIndex(where: { $0.hasSuffix("{") }) else {
                XCTFail("\(operation.rawValue): no function body opens above the guard")
                continue
            }
            let preamble = lines[(bodyIndex + 1)..<guardIndex]
            XCTAssertEqual(
                preamble.filter { $0 == "#if os(macOS)" }.count,
                1,
                "\(operation.rawValue): guard must sit in an `#if os(macOS)` branch"
            )
            XCTAssertTrue(
                preamble.allSatisfy { $0 == "#if os(macOS)" || $0.hasPrefix("//") || $0.isEmpty },
                "\(operation.rawValue): guard must be the function's first statement, found \(Array(preamble))"
            )
            XCTAssertEqual(
                lines[(guardIndex + 1)...].first { $0.hasPrefix("#") },
                "#endif",
                "\(operation.rawValue): the macOS branch must close without an `#else`"
            )
        }
    }

    /// The app target's Swift sources other than the tripwire's own files,
    /// each as whitespace-trimmed lines.
    private func appSources() throws -> [(fileName: String, lines: [String])] {
        // This file is esc-chatmailTests/Security/, so the repo root is three
        // directories up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = repoRoot.appendingPathComponent("esc-chatmail", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: appRoot.appendingPathComponent("Services/Security/SandboxTripwire.swift").path
            ),
            "Scan root must be the app target: \(appRoot.path)"
        )

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var sources: [(fileName: String, lines: [String])] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard !fileURL.lastPathComponent.hasPrefix("SandboxTripwire") else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            sources.append((fileName: fileURL.lastPathComponent, lines: lines))
        }
        XCTAssertGreaterThan(sources.count, 100, "Expected to scan the app's Swift sources at \(appRoot.path)")
        return sources
    }
}
