import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// A pasted picture is put in a form the draft's import takes as an image
/// (`PastedImageEncoder`). ImageIO only, so this runs in the iOS suite and in
/// `Mac.xctestplan`.
final class PastedImageEncoderTests: XCTestCase {
    private let size = CGSize(width: 120, height: 80)

    // MARK: - As it came, or written again

    /// A picture of a kind the import knows is written as it came: these are the page's own
    /// bytes where they come out of what a web view copied.
    ///
    /// Revert-check: answering `reencoded(from: source)` for every picture in
    /// `PastedImageEncoder.attachable`, without the `mimeType(forPathExtension:)` branch,
    /// makes the JPEG's assertions fail: its bytes are a new encoding.
    func testAttachable_ofAKindTheImportKnows_isTheBytesAsTheyCame() throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSize: size, picture: .photograph, hasAlphaChannel: false)
        let png = try TestImageData.encoded(as: .png, pixelSizes: [size])
        let gif = try TestImageData.encoded(as: .gif, pixelSizes: [size])

        XCTAssertEqual(PastedImageEncoder.attachable(from: jpeg), .init(data: jpeg, fileExtension: "jpeg"))
        XCTAssertEqual(PastedImageEncoder.attachable(from: png), .init(data: png, fileExtension: "png"))
        XCTAssertEqual(PastedImageEncoder.attachable(from: gif), .init(data: gif, fileExtension: "gif"))
    }

    /// The extension a picture is written under is one the import takes as an image, or the
    /// picture would be attached as a plain file.
    func testAttachable_alwaysNamesAnExtensionTheImportTakesAsAnImage() throws {
        let pictures = [
            try TestImageData.encoded(as: .jpeg, pixelSize: size, picture: .photograph, hasAlphaChannel: false),
            try TestImageData.encoded(as: .png, pixelSizes: [size]),
            try TestImageData.encoded(as: .gif, pixelSizes: [size]),
            try TestImageData.encoded(as: .tiff, pixelSizes: [size]),
            try TestImageData.encoded(as: .tiff, pixelSize: size, picture: .photograph, hasAlphaChannel: false),
            try TestImageData.encoded(as: .bmp, pixelSizes: [size])
        ]

        for picture in pictures {
            let attachable = try XCTUnwrap(PastedImageEncoder.attachable(from: picture))
            let mimeType = DocumentAttachmentImporter.mimeType(forPathExtension: attachable.fileExtension)
            XCTAssertTrue(mimeType.hasPrefix("image/"), attachable.fileExtension)
        }
    }

    /// The import knows no MIME type for `.tiff` and attached one as a plain file,
    /// uncompressed.
    ///
    /// Revert-check: adding `"tiff", "tif"` as `image/tiff` to
    /// `DocumentAttachmentImporter.mimeType(forPathExtension:)` makes this fail: the TIFF is
    /// written as it came.
    func testAttachable_ofATIFF_isWrittenAgain() throws {
        let tiff = try TestImageData.encoded(as: .tiff, pixelSizes: [size])

        let attachable = try XCTUnwrap(PastedImageEncoder.attachable(from: tiff))

        XCTAssertEqual(attachable.fileExtension, "png")
        XCTAssertEqual(TestImageData.typeIdentifier(of: attachable.data), UTType.png.identifier)
        XCTAssertEqual(TestImageData.pixelSizes(of: attachable.data), [size])
    }

    /// Revert-check: answering `Attachable(data: data, fileExtension: "png")` from
    /// `PastedImageEncoder.attachable` where no image could be read makes this fail.
    func testAttachable_ofBytesThatAreNoImage_isNil() {
        XCTAssertNil(PastedImageEncoder.attachable(from: Data("not an image".utf8)))
        XCTAssertNil(PastedImageEncoder.attachable(from: Data()))
        XCTAssertNil(PastedImageEncoder.reencoded(from: Data("not an image".utf8)))
    }

    /// A PDF attached in rich text is not a picture, and is not made into one. ImageIO names
    /// a PDF's kind and cannot write it again (measured 2026-11-14 on macOS 27.2.1: the PNG
    /// was not made), which is what leaves it out.
    ///
    /// HONEST SCOPE: no line of `PastedImageEncoder` is behind this, so there is no
    /// revert-check. It pins what ImageIO does: if it fails, ImageIO has started drawing
    /// PDFs, and `attachable` has to ask whether the kind it read is an image.
    func testAttachable_ofAPDF_isNil() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        XCTAssertGreaterThan(data.length, 0)

        XCTAssertNil(PastedImageEncoder.attachable(from: data as Data))
    }

    // MARK: - PNG or JPEG

    /// A photograph that has to be written again is several times the size as PNG.
    ///
    /// Revert-check: answering `lossless` always from `PastedImageEncoder.reencoded`
    /// (dropping the JPEG branch) makes this fail: the photograph is a PNG again, which for
    /// a picture copied as TIFF was 6.4 MB against 0.96 MB.
    func testReencoded_aPhotographWithNoAlpha_isAJPEG_underHalfItsPNG() throws {
        let tiff = try TestImageData.encoded(as: .tiff, pixelSize: size, picture: .photograph, hasAlphaChannel: false)
        let png = try TestImageData.encoded(as: .png, pixelSize: size, picture: .photograph, hasAlphaChannel: false)

        let reencoded = try XCTUnwrap(PastedImageEncoder.reencoded(from: tiff))

        XCTAssertEqual(reencoded.fileExtension, "jpg")
        XCTAssertEqual(TestImageData.typeIdentifier(of: reencoded.data), UTType.jpeg.identifier)
        XCTAssertEqual(TestImageData.pixelSizes(of: reencoded.data), [size])
        // The premise: this picture is one PNG does badly with.
        XCTAssertLessThanOrEqual(reencoded.data.count, png.count / 2)
    }

    /// A flat picture, as a page of text or a chart is, is small as PNG and loses nothing.
    ///
    /// Revert-check: answering true from `PastedImageEncoder.prefersJPEG` for any picture
    /// with no alpha makes this fail: the flat picture is written as a JPEG larger than its
    /// PNG.
    func testReencoded_aFlatPictureWithNoAlpha_staysAPNG() throws {
        let tiff = try TestImageData.encoded(as: .tiff, pixelSize: size, picture: .flat, hasAlphaChannel: false)

        let reencoded = try XCTUnwrap(PastedImageEncoder.reencoded(from: tiff))

        XCTAssertEqual(reencoded.fileExtension, "png")
        XCTAssertEqual(TestImageData.typeIdentifier(of: reencoded.data), UTType.png.identifier)
    }

    /// JPEG has no transparency, so a picture whose file says it has an alpha channel stays
    /// PNG however much smaller its JPEG would be.
    ///
    /// Revert-check: answering false always from `PastedImageEncoder.hasAlpha(_:at:)` makes
    /// this fail: the picture is flattened into a JPEG.
    func testReencoded_aPhotographWithAnAlphaChannel_staysAPNG() throws {
        let tiff = try TestImageData.encoded(as: .tiff, pixelSize: size, picture: .photograph, hasAlphaChannel: true)

        let reencoded = try XCTUnwrap(PastedImageEncoder.reencoded(from: tiff))

        XCTAssertEqual(reencoded.fileExtension, "png")
        XCTAssertEqual(TestImageData.typeIdentifier(of: reencoded.data), UTType.png.identifier)
        XCTAssertEqual(TestImageData.pixelSizes(of: reencoded.data), [size])
    }

    /// Revert-check: dropping the `!hasAlpha` term from `PastedImageEncoder.prefersJPEG`
    /// makes the second assertion fail, and comparing with the whole PNG
    /// (`jpegByteCount <= pngByteCount`) makes the fourth fail: a JPEG barely smaller than
    /// its PNG would be taken, and the picture's sharp edges lost for nothing.
    func testPrefersJPEG_onlyWithNoAlpha_andUnderHalfThePNG() {
        XCTAssertTrue(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: 6_400_000, jpegByteCount: 960_000))
        XCTAssertFalse(PastedImageEncoder.prefersJPEG(hasAlpha: true, pngByteCount: 6_400_000, jpegByteCount: 960_000))
        XCTAssertTrue(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: 1000, jpegByteCount: 500))
        XCTAssertFalse(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: 1000, jpegByteCount: 501))
        // A page of text: 0.99 MB as PNG, 3.0 MB as JPEG.
        XCTAssertFalse(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: 990_000, jpegByteCount: 3_000_000))
        XCTAssertFalse(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: 1000, jpegByteCount: 0))
        XCTAssertFalse(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: 0, jpegByteCount: 0))
        XCTAssertFalse(PastedImageEncoder.prefersJPEG(hasAlpha: false, pngByteCount: .max, jpegByteCount: .max))
    }

    // MARK: - A TIFF of several sizes

    /// An `NSImage` with a 1x and a 2x representation is copied as one TIFF holding both.
    ///
    /// Revert-check: encoding index 0 in `PastedImageEncoder.reencoded(from:)`, in place of
    /// `largestImageIndex`, makes this fail: the smaller picture is the one attached.
    func testReencoded_aTIFFHoldingTwoSizes_isTheLarger() throws {
        let small = CGSize(width: 16, height: 16)
        let large = CGSize(width: 32, height: 32)
        let tiff = try TestImageData.encoded(as: .tiff, pixelSizes: [small, large])
        // Both are in the file, the smaller first.
        XCTAssertEqual(TestImageData.pixelSizes(of: tiff), [small, large])

        let reencoded = try XCTUnwrap(PastedImageEncoder.reencoded(from: tiff))

        XCTAssertEqual(TestImageData.pixelSizes(of: reencoded.data), [large])
    }
}
