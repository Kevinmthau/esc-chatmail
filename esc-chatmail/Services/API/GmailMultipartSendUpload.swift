import Foundation

/// The body of one messages.send upload (`uploadType=multipart`), written to a file so
/// the send session streams it from disk (`URLSession.upload(for:fromFile:)`).
///
/// Before, a send was one in-memory JSON body carrying the whole MIME as base64url
/// (`{"raw": …}`), about 4/3 of the MIME, whose attachments are base64 already: three or
/// four photos on cellular ran into the send's 300 s cap after the barrier and ended as
/// "Delivery unknown". The upload carries the MIME's own bytes (`message/rfc822`) beside
/// a small JSON part with the thread ID, so the request is about a quarter smaller and
/// no copy of it is held in memory as a string.
///
/// Only the body's transport changed. The file is written before the transmission
/// barrier, so a write that fails is a pre-transmission failure ("Not sent"), and every
/// rule of the send path (no retransmission after an ambiguous failure, the barrier, the
/// send session) is the caller's, as before.
struct GmailMultipartSendUpload: Sendable {
    let fileURL: URL
    let boundary: String

    /// The request's `Content-Type`.
    var contentType: String {
        "multipart/related; boundary=\(boundary)"
    }

    /// Where the client writes its upload files: under the app's temporary directory,
    /// which is never backed up.
    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboundSendUploads", isDirectory: true)
    }

    /// A file this old was left by a send that never removed it (the app was killed
    /// mid-send). One attempt is capped at `NetworkConfig.sendResourceTimeout` and a send
    /// with its retries takes about 420 s, so no file in use is ever this old.
    static let staleFileAge: TimeInterval = 3600

    private struct Metadata: Encodable {
        let threadId: String?
    }

    /// Writes the multipart body for `mimeData` into a new file in `directory`.
    ///
    /// The MIME part is `mimeData` byte for byte. The boundary is fresh for every send
    /// and never occurs in the MIME (`makeBoundary` is asked again if it does). Removes
    /// files in `directory` older than `staleFileAge` first.
    static func write(
        mimeData: Data,
        threadId: String?,
        in directory: URL,
        now: Date = Date(),
        makeBoundary: () -> String = { "esc-chatmail-\(UUID().uuidString)" }
    ) throws -> GmailMultipartSendUpload {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStaleFiles(in: directory, now: now)

        var boundary = makeBoundary()
        while mimeData.range(of: Data(boundary.utf8)) != nil {
            boundary = makeBoundary()
        }

        let metadata = try JSONEncoder().encode(Metadata(threadId: threadId))
        var head = Data()
        head.append(Data("--\(boundary)\r\n".utf8))
        head.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        head.append(metadata)
        head.append(Data("\r\n--\(boundary)\r\n".utf8))
        head.append(Data("Content-Type: message/rfc822\r\n\r\n".utf8))
        let tail = Data("\r\n--\(boundary)--\r\n".utf8)

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).multipart")
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: head)
            try handle.write(contentsOf: mimeData)
            try handle.write(contentsOf: tail)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }

        return GmailMultipartSendUpload(fileURL: fileURL, boundary: boundary)
    }

    /// Removes the file. A file already gone is not an error.
    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func removeStaleFiles(in directory: URL, now: Date) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                now.timeIntervalSince(modified) > staleFileAge else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
