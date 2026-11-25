import XCTest
@testable import esc_chatmail

/// What of a MetricKit payload is kept on the device (architecture review 2026-11,
/// `observability-errors#1`). MetricKit payloads have no public initializer, so these
/// feed the projection the JSON shape `jsonRepresentation()` produces.
final class DiagnosticsPayloadProjectionTests: XCTestCase {
    private let address = "someone@example.com"

    // Revert-check: fails if `exceptionReasonKeys` (or `projectMetaData`'s filtering of the
    // exception reason) lets `composedMessage`, `arguments` or `formatString` through.
    func testCrash_exceptionTextIsDropped_nameTypeAndClassKept() throws {
        let kept = try projected(.diagnostic, crashPayload())

        XCTAssertFalse(String(decoding: try XCTUnwrap(DiagnosticsPayloadProjection.project(kind: .diagnostic, json: crashPayload())), as: UTF8.self).contains(address))
        let crash = try XCTUnwrap((kept["crashDiagnostics"] as? [[String: Any]])?.first)
        let metaData = try XCTUnwrap(crash["diagnosticMetaData"] as? [String: Any])
        let reason = try XCTUnwrap(metaData["objectiveCexceptionReason"] as? [String: Any])
        XCTAssertEqual(Set(reason.keys), ["type", "className", "exceptionName"])
        XCTAssertEqual(reason["exceptionName"] as? String, "NSInvalidArgumentException")
        XCTAssertEqual(metaData["signal"] as? Int, 6)
        XCTAssertEqual(metaData["terminationReason"] as? String, "Namespace SIGNAL, Code 0x6")
        XCTAssertNil(metaData["regionFormat"], "Not on the allowlist")
    }

    // Revert-check: fails if `projectCallStackTree` / `projectFrame` keep frames whole
    // (an unknown frame key would then be stored) or stop following `subFrames`.
    func testCallStackTree_keepsStructureAndOnlyAllowlistedFrameKeys() throws {
        let kept = try projected(.diagnostic, crashPayload())
        let crash = try XCTUnwrap((kept["crashDiagnostics"] as? [[String: Any]])?.first)
        let tree = try XCTUnwrap(crash["callStackTree"] as? [String: Any])
        let stack = try XCTUnwrap((tree["callStacks"] as? [[String: Any]])?.first)
        XCTAssertEqual(stack["threadAttributed"] as? Bool, true)
        let frame = try XCTUnwrap((stack["callStackRootFrames"] as? [[String: Any]])?.first)
        XCTAssertEqual(frame["binaryName"] as? String, "esc-chatmail")
        XCTAssertNil(frame["futureFreeText"])
        let subFrame = try XCTUnwrap((frame["subFrames"] as? [[String: Any]])?.first)
        XCTAssertEqual(subFrame["binaryName"] as? String, "Foundation")
        XCTAssertNil(subFrame["futureFreeText"])
    }

    func testDiagnostic_unknownTopLevelKeysAreDropped() throws {
        var payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: crashPayload()) as? [String: Any])
        payload["futureDiagnostics"] = [["note": address]]
        let json = try JSONSerialization.data(withJSONObject: payload)

        let kept = try projected(.diagnostic, json)

        XCTAssertNil(kept["futureDiagnostics"])
        XCTAssertNotNil(kept["crashDiagnostics"])
    }

    // Revert-check: fails if `metricSectionKeys` gains `signpostMetrics` or the metrics
    // branch keeps the payload whole.
    func testMetrics_keepsNumericSections_dropsSignposts() throws {
        let payload: [String: Any] = [
            "timeStampBegin": "2026-11-24 00:00:00",
            "timeStampEnd": "2026-11-25 00:00:00",
            "metaData": ["appBuildVersion": "612", "osVersion": "iPhone OS 27.0", "regionFormat": "US"],
            "applicationExitMetrics": [
                "backgroundExitData": ["cumulativeMemoryResourceLimitExitCount": 3]
            ],
            "diskSpaceUsageMetrics": ["totalDataFileSize": "120 MB"],
            "latestApplicationVersion": "1.0",
            "signpostMetrics": [["signpostName": address]]
        ]
        let kept = try projected(.metrics, try JSONSerialization.data(withJSONObject: payload))

        XCTAssertNil(kept["signpostMetrics"])
        let exits = try XCTUnwrap(kept["applicationExitMetrics"] as? [String: Any])
        XCTAssertNotNil(exits["backgroundExitData"])
        XCTAssertNotNil(kept["diskSpaceUsageMetrics"])
        XCTAssertEqual(kept["latestApplicationVersion"] as? String, "1.0")
        let metaData = try XCTUnwrap(kept["metaData"] as? [String: Any])
        XCTAssertEqual(metaData["appBuildVersion"] as? String, "612")
        XCTAssertNil(metaData["regionFormat"])
    }

    func testNothingToKeep_orNotJSON_isNil() {
        XCTAssertNil(DiagnosticsPayloadProjection.project(kind: .diagnostic, json: Data("not json".utf8)))
        XCTAssertNil(DiagnosticsPayloadProjection.project(
            kind: .diagnostic,
            json: Data(#"{"timeStampBegin":"a","timeStampEnd":"b","other":1}"#.utf8)
        ))
    }

    // MARK: - Fixtures

    private func projected(_ kind: DiagnosticsPayloadProjection.Kind, _ json: Data) throws -> [String: Any] {
        let data = try XCTUnwrap(DiagnosticsPayloadProjection.project(kind: kind, json: json))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func crashPayload() -> Data {
        let payload: [String: Any] = [
            "timeStampBegin": "2026-11-24 10:00:00",
            "timeStampEnd": "2026-11-24 10:00:00",
            "crashDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": [
                    "appBuildVersion": "612",
                    "appVersion": "1.0",
                    "osVersion": "iPhone OS 27.0",
                    "regionFormat": "US",
                    "signal": 6,
                    "exceptionType": 10,
                    "terminationReason": "Namespace SIGNAL, Code 0x6",
                    "objectiveCexceptionReason": [
                        "composedMessage": "Could not find \(address)",
                        "formatString": "Could not find \(address)",
                        "arguments": [address],
                        "type": "NSException",
                        "className": "NSException",
                        "exceptionName": "NSInvalidArgumentException"
                    ]
                ],
                "callStackTree": [
                    "callStackPerThread": true,
                    "callStacks": [[
                        "threadAttributed": true,
                        "callStackRootFrames": [[
                            "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
                            "offsetIntoBinaryTextSegment": 123,
                            "sampleCount": 1,
                            "binaryName": "esc-chatmail",
                            "address": 7_447_059_544,
                            "futureFreeText": address,
                            "subFrames": [[
                                "binaryUUID": "1B2A3C4D-0000-0000-0000-000000000000",
                                "offsetIntoBinaryTextSegment": 456,
                                "sampleCount": 1,
                                "binaryName": "Foundation",
                                "address": 7_447_059_600,
                                "futureFreeText": address
                            ]]
                        ]]
                    ]]
                ]
            ]]
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
