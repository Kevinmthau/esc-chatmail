import Foundation

/// What of a MetricKit payload is kept on the device (`DiagnosticsRecordStore`): an
/// allowlist, applied to the payload's `jsonRepresentation()` before anything is written.
///
/// Everything not named here is dropped, so a key MetricKit adds later is not kept until
/// someone decides it may be. One exception: a metric section that is named
/// (`metricSectionKeys`) is kept whole, because every one of them is numbers and unit
/// strings; a section added to that list must be checked for free text first. In particular an Objective-C exception's `composedMessage`,
/// `arguments` and `formatString` are dropped: they are the exception's text, and the
/// text of an exception raised over a message or a contact can hold an address or a
/// subject (CLAUDE.md, Logging: redaction is a hard rule). Its name, type and class are
/// kept. The call-stack trees keep their structure and, in each frame, only the binary's
/// name and UUID, the offset, the address and the sample count, which are the app's and
/// the system's, never the user's. A metric payload keeps
/// its numeric sections and drops `signpostMetrics`, whose names are free text.
///
/// Architecture review 2026-11, `observability-errors#1`.
enum DiagnosticsPayloadProjection {
    enum Kind: String, CaseIterable, Sendable {
        /// An `MXDiagnosticPayload`: crashes, hangs, CPU and disk-write exceptions, slow launches.
        case diagnostic
        /// An `MXMetricPayload`: the daily aggregates (exits by reason, launch and hang times, memory).
        case metrics
    }

    static let diagnosticArrayKeys: Set<String> = [
        "crashDiagnostics",
        "hangDiagnostics",
        "cpuExceptionDiagnostics",
        "diskWriteExceptionDiagnostics",
        "appLaunchDiagnostics"
    ]

    static let metricSectionKeys: Set<String> = [
        "applicationExitMetrics",
        "applicationLaunchMetrics",
        "applicationResponsivenessMetrics",
        "applicationTimeMetrics",
        "memoryMetrics",
        "cpuMetrics",
        "diskIOMetrics",
        "diskSpaceUsageMetrics",
        "animationMetrics"
    ]

    static let metricTopLevelKeys: Set<String> = [
        "latestApplicationVersion",
        "includesMultipleApplicationVersions"
    ]

    static let metaDataKeys: Set<String> = [
        "appBuildVersion",
        "appVersion",
        "osVersion",
        "deviceType",
        "platformArchitecture",
        "isTestFlightApp",
        "lowPowerModeEnabled",
        "bundleIdentifier",
        "exceptionType",
        "exceptionCode",
        "signal",
        "terminationReason",
        "virtualMemoryRegionInfo",
        "hangDuration",
        "launchDuration",
        "totalCPUTime",
        "totalSampledTime",
        "writesCaused",
        "objectiveCexceptionReason"
    ]

    static let exceptionReasonKeys: Set<String> = ["type", "className", "exceptionName"]

    static let callStackTreeKeys: Set<String> = ["callStackPerThread"]
    static let callStackKeys: Set<String> = ["threadAttributed"]
    static let frameKeys: Set<String> = [
        "binaryUUID",
        "binaryName",
        "offsetIntoBinaryTextSegment",
        "address",
        "sampleCount"
    ]

    /// The kept part of a payload, as JSON, or nil when the input is not a JSON object or
    /// nothing of it is kept.
    static func project(kind: Kind, json: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }
        var projected: [String: Any] = [:]
        for key in ["timeStampBegin", "timeStampEnd"] {
            if let value = object[key] as? String {
                projected[key] = value
            }
        }
        switch kind {
        case .diagnostic:
            for key in diagnosticArrayKeys {
                guard let diagnostics = object[key] as? [[String: Any]] else { continue }
                let kept = diagnostics.map(projectDiagnostic)
                if !kept.isEmpty {
                    projected[key] = kept
                }
            }
        case .metrics:
            if let metaData = object["metaData"] as? [String: Any] {
                projected["metaData"] = projectMetaData(metaData)
            }
            for key in metricTopLevelKeys {
                if let value = object[key], value is String || value is NSNumber {
                    projected[key] = value
                }
            }
            for key in metricSectionKeys {
                if let section = object[key] as? [String: Any] {
                    projected[key] = section
                }
            }
        }
        guard projected.keys.contains(where: { $0 != "timeStampBegin" && $0 != "timeStampEnd" }),
              JSONSerialization.isValidJSONObject(projected) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys])
    }

    private static func projectDiagnostic(_ diagnostic: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = [:]
        if let version = diagnostic["version"] as? String {
            kept["version"] = version
        }
        if let callStackTree = diagnostic["callStackTree"] as? [String: Any] {
            kept["callStackTree"] = projectCallStackTree(callStackTree)
        }
        if let metaData = diagnostic["diagnosticMetaData"] as? [String: Any] {
            kept["diagnosticMetaData"] = projectMetaData(metaData)
        }
        return kept
    }

    private static func projectCallStackTree(_ tree: [String: Any]) -> [String: Any] {
        var kept = tree.filter { callStackTreeKeys.contains($0.key) }
        if let callStacks = tree["callStacks"] as? [[String: Any]] {
            kept["callStacks"] = callStacks.map { callStack -> [String: Any] in
                var keptStack = callStack.filter { callStackKeys.contains($0.key) }
                if let frames = callStack["callStackRootFrames"] as? [[String: Any]] {
                    keptStack["callStackRootFrames"] = frames.map(projectFrame)
                }
                return keptStack
            }
        }
        return kept
    }

    private static func projectFrame(_ frame: [String: Any]) -> [String: Any] {
        var kept = frame.filter { frameKeys.contains($0.key) }
        if let subFrames = frame["subFrames"] as? [[String: Any]] {
            kept["subFrames"] = subFrames.map(projectFrame)
        }
        return kept
    }

    private static func projectMetaData(_ metaData: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = [:]
        for (key, value) in metaData where metaDataKeys.contains(key) {
            if key == "objectiveCexceptionReason" {
                guard let reason = value as? [String: Any] else { continue }
                kept[key] = reason.filter { exceptionReasonKeys.contains($0.key) }
            } else {
                kept[key] = value
            }
        }
        return kept
    }
}
