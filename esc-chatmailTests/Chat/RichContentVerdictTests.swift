import XCTest
@testable import esc_chatmail

/// The persisted encoding of `Message.richContentVerdict`. Rows on disk hold these integers,
/// so the literal values and the epoch rule are a storage contract, not an implementation
/// detail.
final class RichContentVerdictTests: XCTestCase {
    private let currentEpoch = CacheVersioning.richContentVerdictEpoch

    /// An epoch that is not the current one, whatever the current one is bumped to.
    private var otherEpoch: Int16 {
        currentEpoch == 1 ? 2 : currentEpoch - 1
    }

    // MARK: - Encoding

    /// Revert-check: `RichContentVerdict.storedValue(epoch:)` returning anything but 0 for
    /// unknown and `epoch * 2 + (rich ? 1 : 0)` otherwise fails the literals.
    func testStoredValue_eachVerdict_encodesEpochAndRichBit() {
        XCTAssertEqual(RichContentVerdict.unknown.storedValue(epoch: 1), 0)
        XCTAssertEqual(RichContentVerdict.notRich.storedValue(epoch: 1), 2)
        XCTAssertEqual(RichContentVerdict.rich.storedValue(epoch: 1), 3)

        XCTAssertEqual(RichContentVerdict.unknown.storedValue(epoch: 7), 0)
        XCTAssertEqual(RichContentVerdict.notRich.storedValue(epoch: 7), 14)
        XCTAssertEqual(RichContentVerdict.rich.storedValue(epoch: 7), 15)
    }

    /// 16383 is the largest epoch an Int16 can hold (`16383 * 2 + 1 == Int16.max`).
    ///
    /// Revert-check: decoding the rich bit from anything but `storedValue % 2` in
    /// `RichContentVerdict.init(storedValue:epoch:)` swaps or collapses the two verdicts.
    func testStoredValue_notRichAndRich_roundTripUnderTheirOwnEpoch() {
        for epoch: Int16 in [1, 2, 7, 16_383] {
            for verdict in [RichContentVerdict.notRich, .rich] {
                let storedValue = verdict.storedValue(epoch: epoch)
                XCTAssertEqual(
                    RichContentVerdict(storedValue: storedValue, epoch: epoch),
                    verdict,
                    "\(verdict) under epoch \(epoch)"
                )
            }
        }
    }

    /// The accessors on `Message` call both functions with no epoch argument.
    ///
    /// Revert-check: either default argument naming something other than
    /// `CacheVersioning.richContentVerdictEpoch`. The range assertion fails a bump past what
    /// an Int16 can encode.
    func testStoredValueAndInit_defaultEpoch_isTheCacheVersioningEpoch() {
        XCTAssertTrue((1...16_383).contains(currentEpoch))

        for verdict in [RichContentVerdict.notRich, .rich] {
            XCTAssertEqual(verdict.storedValue(), verdict.storedValue(epoch: currentEpoch))
            XCTAssertEqual(RichContentVerdict(storedValue: verdict.storedValue(epoch: currentEpoch)), verdict)
            XCTAssertEqual(RichContentVerdict(storedValue: verdict.storedValue(epoch: otherEpoch)), .unknown)
        }
    }

    // MARK: - Decoding unknown

    /// A never-stamped row holds 0 (or NULL, which the scalar reads as 0).
    ///
    /// HONEST SCOPE: 0 fails both the `storedValue >= 2` guard and the epoch comparison in
    /// `RichContentVerdict.init(storedValue:epoch:)`, so removing either one alone leaves this
    /// green. It pins the contract, and fails only if both go.
    func testInitStoredValue_zero_decodesUnknown() {
        for epoch: Int16 in [1, 2, 7, 16_383] {
            XCTAssertEqual(RichContentVerdict(storedValue: 0, epoch: epoch), .unknown, "epoch \(epoch)")
        }
        XCTAssertEqual(RichContentVerdict(storedValue: 0), .unknown)
        XCTAssertEqual(RichContentVerdict.unknown.storedValue(), 0)
    }

    /// A verdict stamped by older (or newer) classifier code must not read as a known one:
    /// the bubble would render it at mount and its load would then contradict it.
    ///
    /// Revert-check: the `storedValue / 2 == epoch` comparison in
    /// `RichContentVerdict.init(storedValue:epoch:)`. Without it 3 (rich under epoch 1) read
    /// under epoch 2 decodes `.rich`.
    func testInitStoredValue_valueStampedUnderAnotherEpoch_decodesUnknown() {
        let epochs: [Int16] = [1, 2, 7, 16_383]
        for stampedEpoch in epochs {
            for readingEpoch in epochs where readingEpoch != stampedEpoch {
                for verdict in [RichContentVerdict.notRich, .rich] {
                    XCTAssertEqual(
                        RichContentVerdict(
                            storedValue: verdict.storedValue(epoch: stampedEpoch),
                            epoch: readingEpoch
                        ),
                        .unknown,
                        "\(verdict) stamped under epoch \(stampedEpoch), read under \(readingEpoch)"
                    )
                }
            }
        }
    }

    /// No epoch produces 1 or a negative value.
    ///
    /// HONEST SCOPE: under a valid epoch these values fail both the `storedValue >= 2` guard
    /// and the epoch comparison in `RichContentVerdict.init(storedValue:epoch:)`, so a single
    /// removed guard leaves this green. It pins the contract, and fails only if both go.
    func testInitStoredValue_oneAndNegativeValues_decodeUnknown() {
        let valuesNoEpochProduces: [Int16] = [1, -1, -2, -3, -4, .min]
        for epoch: Int16 in [1, 2, 7] {
            for value in valuesNoEpochProduces {
                XCTAssertEqual(
                    RichContentVerdict(storedValue: value, epoch: epoch),
                    .unknown,
                    "value \(value) under epoch \(epoch)"
                )
            }
        }
    }

    /// An epoch below 1 has no encodings of its own: its `notRich` would be 0, the unknown
    /// value.
    ///
    /// HONEST SCOPE: the `epoch >= 1` and `storedValue >= 2` guards in
    /// `RichContentVerdict.init(storedValue:epoch:)` are mutually redundant, so this fails only
    /// when both are removed: 1 under epoch 0 then decodes `.rich`, and 0 under epoch 0 and -2
    /// under epoch -1 decode `.notRich`.
    func testInitStoredValue_epochBelowOne_decodesUnknown() {
        XCTAssertEqual(RichContentVerdict(storedValue: 0, epoch: 0), .unknown)
        XCTAssertEqual(RichContentVerdict(storedValue: 1, epoch: 0), .unknown)
        XCTAssertEqual(RichContentVerdict(storedValue: -2, epoch: -1), .unknown)
    }

    /// Every value a row could hold decodes to the one verdict whose encoding it is, and to
    /// unknown otherwise.
    ///
    /// Revert-check: the epoch comparison in `RichContentVerdict.init(storedValue:epoch:)`.
    /// Without it every value from 2 up decodes as a known verdict.
    func testInitStoredValue_everyInt16_decodesOnlyItsOwnEncoding() {
        for epoch: Int16 in [1, 2, 16_383] {
            let notRichValue = RichContentVerdict.notRich.storedValue(epoch: epoch)
            let richValue = RichContentVerdict.rich.storedValue(epoch: epoch)
            var misdecodedValues: [Int16] = []

            for value in Int16.min...Int16.max {
                let expected: RichContentVerdict
                if value == notRichValue {
                    expected = .notRich
                } else if value == richValue {
                    expected = .rich
                } else {
                    expected = .unknown
                }
                if RichContentVerdict(storedValue: value, epoch: epoch) != expected {
                    misdecodedValues.append(value)
                }
            }

            XCTAssertEqual(misdecodedValues, [], "epoch \(epoch)")
        }
    }

    // MARK: - Bool bridging

    /// nil is "no verdict", which the loader's `computed ?? stored.isRich ?? false` chain and
    /// `ChatMessageRowModelMapper.knownRichContentVerdict` both rely on.
    ///
    /// Revert-check: `RichContentVerdict.isRich` answering false for `.unknown`.
    func testIsRich_eachVerdict_isNilFalseOrTrue() {
        XCTAssertNil(RichContentVerdict.unknown.isRich)
        XCTAssertEqual(RichContentVerdict.notRich.isRich, false)
        XCTAssertEqual(RichContentVerdict.rich.isRich, true)
    }

    /// Revert-check: `RichContentVerdict.init(isRich:)` mapping either Bool to another case.
    func testInitIsRich_bool_isRichOrNotRichNeverUnknown() {
        XCTAssertEqual(RichContentVerdict(isRich: true), .rich)
        XCTAssertEqual(RichContentVerdict(isRich: false), .notRich)
        XCTAssertEqual(RichContentVerdict(isRich: true).isRich, true)
        XCTAssertEqual(RichContentVerdict(isRich: false).isRich, false)
    }
}
