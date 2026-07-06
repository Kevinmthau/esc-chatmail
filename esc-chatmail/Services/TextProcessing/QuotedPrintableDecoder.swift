import Foundation

/// Minimal quoted-printable decoder for email bodies.
/// Handles soft line breaks and =XX hex escapes.
struct QuotedPrintableDecoder {
    static func decode(_ text: String) -> String {
        let data = decodeToData(text)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeToData(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 61 { // '='
                // Soft line break: "=\r\n" or "=\n"
                if i + 1 < bytes.count {
                    let next = bytes[i + 1]
                    if next == 10 { // \n
                        i += 2
                        continue
                    }
                    if next == 13 { // \r
                        if i + 2 < bytes.count, bytes[i + 2] == 10 {
                            i += 3
                            continue
                        }
                    }
                }

                // Hex escape: =XX
                if i + 2 < bytes.count,
                   let hi = hexValue(bytes[i + 1]),
                   let lo = hexValue(bytes[i + 2]) {
                    output.append(hi * 16 + lo)
                    i += 3
                    continue
                }

                // Fallback: keep literal '='
                output.append(byte)
                i += 1
            } else {
                output.append(byte)
                i += 1
            }
        }

        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48       // 0-9
        case 65...70: return byte - 55       // A-F
        case 97...102: return byte - 87      // a-f
        default: return nil
        }
    }
}
