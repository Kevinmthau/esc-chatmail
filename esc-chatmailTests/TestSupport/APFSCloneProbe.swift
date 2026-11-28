import Darwin
import Foundation

/// Whether a file on APFS may share its blocks with another, which a clone does and a copy
/// does not: `ATTR_CMNEXT_EXT_FLAGS` read through `getattrlist`, tested for
/// `EF_MAY_SHARE_BLOCKS`. Nil where the attribute could not be read.
enum APFSCloneProbe {
    static func mayShareBlocks(_ url: URL) -> Bool? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        // A 32-bit length, then the 64-bit flags.
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(url.path, &request, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0 else { return nil }
        let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
    }
}
