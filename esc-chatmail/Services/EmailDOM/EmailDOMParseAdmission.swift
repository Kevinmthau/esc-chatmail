import Foundation
import SwiftSoup

/// The one place SwiftSoup is asked to parse a string of HTML (pinned by
/// `EmailDOMParseAdmissionSourceTests`). SwiftSoup's `Element` methods that
/// take HTML (`html(_:)`, `append(_:)`, `prepend(_:)`, `before(_:)`,
/// `after(_:)`, `wrap(_:)`) parse too, and must only be given strings the app
/// builds, never a sender's.
///
/// Nesting depth is the sender's to choose, and both SwiftSoup and the app
/// recurse once per level: releasing a document frees each node from inside
/// its parent's release, and every DOM walker in `EmailDOM` calls itself for
/// each child. On a 512 KB thread (every cooperative-pool thread, so every
/// sync task) releasing a parsed document overflowed the stack at about
/// 1,030 levels in a Debug build and 1,270 in Release (measured 2026-11-23,
/// SwiftSoup 2.13.5, macOS 27.2, near-empty base stack; a nest of
/// `<div>`s, of `<table><td>` pairs and of `<p><b>x</p>` lines all gave the
/// same per-level cost). A crash there was a crash loop: nothing records a
/// verdict for the message, so every launch's sync fetched and processed
/// it again. Parsing nested tables is also quadratic in SwiftSoup (16,000
/// levels took 26 s), so depth bounds the CPU of a parse too.
///
/// So no tree deeper than `maximumDepth` reaches a caller, and none is
/// built or released on the caller's stack. A refusal throws
/// `EmailDOMParseRefusal`, and that is not new behavior for any caller:
/// each already handles a throwing parse, and that branch now runs (text
/// extraction's regex recovery, quote removal returning its input, the
/// display wrapper's string wrapping, a preview query of nil). The one
/// exception is the sanitizer: its legacy regex pass is not safe against a
/// crafted body, so a refused body is shown as escaped text
/// (`HTMLSanitizerService.textOnlyReplacement(forRefusedHTML:)`). The answer is a pure function of the string, so
/// the ingest prerun and a later bubble load always agree.
///
/// Each parse goes one of three ways, by `estimatedDepth(of:limit:)`, a scan
/// of the UTF-8 bytes for an upper bound on the depth of SwiftSoup's tree:
/// - At most `maximumDepth`: parsed here, as before. Nearly all mail.
/// - Past `maximumBoundForMeasuredParse`: refused without parsing.
/// - Between: parsed on a thread of its own with a large stack, where the
///   tree's real depth is measured without recursion. It is handed back if
///   it is within `maximumDepth` and released on that thread otherwise. The
///   scan over-counts what it cannot be sure the tree builder closes (an
///   optional end tag left out before its parent's, `<ul><li>a</ul>`), so
///   a large old-style newsletter can land here and still be admitted.
/// Every admitted tree is measured too, and one deeper than `maximumDepth`
/// is refused and released on that thread. That backstop is partial: such a
/// tree was already built on the caller's stack, where building it recurses
/// too, and the measuring thread's stack runs out near 65,000 levels. The
/// scan's bound is what must hold.
///
/// The bound must never be lower than the real depth. Two scans give it:
/// - Every `<` followed by an ASCII letter, wherever it sits (attribute
///   value, comment, script), is counted as an element that is never closed.
///   That over-counts whatever the tokenizer does, so a body whose count
///   passes needs no second scan.
/// - Otherwise the bytes are tokenized as SwiftSoup 2.13.5 tokenizes them
///   (tag and attribute states, comments, bogus comments, doctype, CDATA,
///   the raw text of `title`, `style`, `noframes`, `script` with its escape
///   states, and `plaintext`), so an end tag inside an attribute value or a
///   style sheet is never taken for a real one. Open elements are popped
///   only by an end tag naming the innermost one, or by a start tag that
///   always closes it (`<p>` closing a `p`, `<td>` a `td`, and so on). Every
///   other closing the tree builder might do is ignored, which can only
///   over-count: an unclosed formatting element stays counted, as the tree
///   builder may reconstruct it any number of times (`<p><b>x</p>` on 1,000
///   lines nests 1,000 deep). Tags the builder may add on its own are
///   counted with the one that implies them (`td` as three: `tbody`, `tr`,
///   `td`).
///   SwiftSoup reads raw text after some tags in one insertion mode and
///   markup in another (`style` inside `select`, anything in a frameset, a
///   `noscript` in the head or the body), so a body naming `select`,
///   `frameset` or `noscript` keeps the first scan's count.
/// `EmailDOMParseAdmissionTests` compares the bound with the depth SwiftSoup
/// builds over generated tag soup; a SwiftSoup upgrade must pass it again.
enum EmailDOMParseAdmission {
    /// The deepest tree handed to a caller, in nodes from the `Document` to
    /// a leaf. Half the measured release overflow in a Debug build, which
    /// leaves room for the stack a sync task already uses and for the app's
    /// walkers, whose Debug frames are the largest. Ordinary mail is far
    /// below it: a few tens of levels, a reply chain of a hundred messages
    /// about three hundred.
    static let maximumDepth = 512

    /// The highest scan bound still parsed (on the measuring thread) to see
    /// the real depth. Above it the parse itself is the hazard: nested
    /// tables this deep parse in about half a second.
    static let maximumBoundForMeasuredParse = 8_192

    /// The measuring thread's stack: a tree `maximumBoundForMeasuredParse`
    /// deep needs about 4 MB to build and release in a Debug build.
    private static let measuringThreadStackSize = 32 * 1024 * 1024

    /// Parses a document, unless it is nested too deeply (`EmailDOMParseRefusal`).
    static func parseDocument(_ html: String) throws -> Document {
        try admittedParse(html, rootDepth: 1, roots: { [$0] }) {
            try SwiftSoup.parse(html)
        }
    }

    /// Parses a body fragment, unless it is nested too deeply (`EmailDOMParseRefusal`).
    static func parseBodyFragment(_ html: String) throws -> Document {
        try admittedParse(html, rootDepth: 1, roots: { [$0] }) {
            try SwiftSoup.parseBodyFragment(html)
        }
    }

    /// Parses a fragment in `context`, unless it is nested too deeply
    /// (`EmailDOMParseRefusal`). The nodes are measured as
    /// `EmailDOMFragmentParser` places them, under a document's `body`.
    static func parseFragment(_ html: String, context: Element) throws -> [Node] {
        try admittedParse(html, rootDepth: enclosingNodeCount + 1, roots: { $0 }) {
            try Parser.parseFragment(html, context, [UInt8]())
        }
    }

    /// Whether `html` would be admitted, without keeping the tree.
    static func admit(_ html: String) throws {
        _ = try parseDocument(html)
    }

    private static func admittedParse<Parsed>(
        _ html: String,
        rootDepth: Int,
        roots: @escaping (Parsed) -> [Node],
        parse: @escaping () throws -> Parsed
    ) throws -> Parsed {
        let cost = estimatedCost(of: html, limit: maximumBoundForMeasuredParse)
        let bound = cost.depth
        if bound > maximumBoundForMeasuredParse {
            throw refusal(depth: bound)
        }
        if let excess = cost.excessWork {
            throw refusal(excessWork: excess)
        }
        if bound > maximumDepth {
            return try parseOnMeasuringThread(rootDepth: rootDepth, roots: roots, parse: parse)
        }

        var parsed: Parsed? = try parse()
        let depth = measuredDepth(of: roots(parsed!), rootDepth: rootDepth)
        guard depth <= maximumDepth else {
            // The scan under-counted. Release the tree where its depth
            // cannot overflow the stack, never here.
            let handOff = MeasuringThreadHandOff<Parsed>()
            handOff.parsed = parsed
            parsed = nil
            runOnMeasuringThread(handOff) { $0.parsed = nil }
            throw refusal(depth: depth)
        }
        return parsed!
    }

    private static func parseOnMeasuringThread<Parsed>(
        rootDepth: Int,
        roots: @escaping (Parsed) -> [Node],
        parse: @escaping () throws -> Parsed
    ) throws -> Parsed {
        let handOff = MeasuringThreadHandOff<Parsed>()
        runOnMeasuringThread(handOff) { handOff in
            do {
                let parsed = try parse()
                let depth = measuredDepth(of: roots(parsed), rootDepth: rootDepth)
                if depth <= maximumDepth {
                    handOff.parsed = parsed
                } else {
                    // `parsed` is released when this closure returns, on
                    // this thread.
                    handOff.error = refusal(depth: depth)
                }
            } catch {
                handOff.error = error
            }
        }
        if let error = handOff.error {
            throw error
        }
        guard let parsed = handOff.parsed else {
            throw refusal(depth: maximumBoundForMeasuredParse)
        }
        return parsed
    }

    /// Runs `work` on a new thread with `measuringThreadStackSize` of stack
    /// and waits for it, at the caller's quality of service so a waiting
    /// main thread is not held behind a lower one.
    private static func runOnMeasuringThread<Parsed>(
        _ handOff: MeasuringThreadHandOff<Parsed>,
        _ work: @escaping (MeasuringThreadHandOff<Parsed>) -> Void
    ) {
        handOff.work = work
        let thread = Thread { handOff.run() }
        thread.stackSize = measuringThreadStackSize
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
        handOff.finished.wait()
    }

    private static func refusal(excessWork: EmailDOMParseRefusal) -> EmailDOMParseRefusal {
        Log.warning("Declined to parse HTML whose parse would cost too much", category: .message)
        return excessWork
    }

    private static func refusal(depth: Int) -> EmailDOMParseRefusal {
        Log.warning(
            "Declined to parse HTML nested past the admission limit (\(depth) > \(maximumDepth))",
            category: .message
        )
        return .nestingTooDeep(depth: depth, limit: maximumDepth)
    }

    /// Nodes on the longest path below `roots`, each root counting as
    /// `rootDepth`, walked without recursion.
    static func measuredDepth(of roots: [Node], rootDepth: Int) -> Int {
        var deepest = 0
        var pending = roots.map { ($0, rootDepth) }
        while let (node, depth) = pending.popLast() {
            deepest = max(deepest, depth)
            for child in node.getChildNodes() {
                pending.append((child, depth + 1))
            }
        }
        return deepest
    }

    /// An upper bound on the number of nodes on the longest path from the
    /// `Document` to a leaf of the tree SwiftSoup would build from `html`
    /// (the document, `html` and `body` included). With a `limit`, the scan
    /// may stop as soon as the bound is known to be past it and return any
    /// value above it.
    static func estimatedDepth(of html: String, limit: Int = .max) -> Int {
        estimatedCost(of: html, limit: limit).depth
    }

    /// What the scans say a parse of `html` would build and cost.
    ///
    /// SwiftSoup's parse is not linear in every input, and the gate runs
    /// before every parse site of a message a sync cannot cancel, so cost is
    /// bounded as well as depth (both measured on SwiftSoup 2.13.5, Release,
    /// by review of PR 453):
    /// - Most start and end tags search the open elements, so a parse costs
    ///   up to depth × tags: `<span>` × 8,000 then 200,000 `</x>` took 83 s.
    ///   `treeWork` is the depth bound times every `<` or `</` followed by a
    ///   letter, wherever it sits.
    /// - Inside a `title`, SwiftSoup searches the rest of the input for an
    ///   end tag at every `<` and letter (`RcdataLessthanSign`), so
    ///   `<title>` then 1 MB of `<a ` took minutes. `titleSearchBytes` is
    ///   the bytes those searches read, from the second scan.
    struct ParseCost: Equatable {
        let depth: Int
        let treeWork: Int
        let titleSearchBytes: Int

        /// The refusal past `maximumTreeWork` or `maximumTitleSearchBytes`.
        var excessWork: EmailDOMParseRefusal? {
            if treeWork > EmailDOMParseAdmission.maximumTreeWork {
                return .tooCostlyToParse(work: treeWork, limit: EmailDOMParseAdmission.maximumTreeWork)
            }
            if titleSearchBytes > EmailDOMParseAdmission.maximumTitleSearchBytes {
                return .tooCostlyToParse(work: titleSearchBytes, limit: EmailDOMParseAdmission.maximumTitleSearchBytes)
            }
            return nil
        }
    }

    /// About a second of the stack searches in a Release build (measured at
    /// about 30 million depth × tag units a second). A large old-style
    /// newsletter, a few thousand levels of over-counted bound over ten
    /// thousand tags, stays under it.
    static let maximumTreeWork = 50_000_000
    /// About a quarter of a second of byte comparisons.
    static let maximumTitleSearchBytes = 200_000_000

    static func estimatedCost(of html: String, limit: Int = .max) -> ParseCost {
        let bytes = html.utf8
        if let cost = bytes.withContiguousStorageIfAvailable({ buffer in
            estimate(in: buffer, limit: limit)
        }) {
            return cost
        }
        return Array(bytes).withUnsafeBufferPointer { estimate(in: $0, limit: limit) }
    }

    /// The second scan alone, without the first scan's shortcut or its
    /// `select`, `frameset` and `noscript` rule. Exposed for the comparison
    /// tests; only `estimatedDepth(of:limit:)` may route a parse.
    static func tokenizedDepthEstimate(of html: String) -> Int {
        let bytes = Array(html.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            var scanner = TokenizingScanner(bytes: buffer, limit: .max)
            return scanner.run()
        }
    }

    /// The document, `html` and `body` (or `head`) above every open element.
    static let enclosingNodeCount = 3
    /// Below the innermost open element: a text node or void element (1), a
    /// `col`'s implied `colgroup` (2), a `td` start tag cut off by the end
    /// of the input with its implied `tbody` and `tr` (3), plus one spare.
    static let leafAllowance = 4

    /// The first scan's count where it already admits a parse here or the
    /// second scan cannot be trusted; otherwise the tighter of the two, both
    /// being upper bounds.
    private static func estimate(in bytes: UnsafeBufferPointer<UInt8>, limit: Int) -> ParseCost {
        let fixed = enclosingNodeCount + leafAllowance
        let count = StartTagCount(bytes: bytes)
        let countedBound = count.weight + fixed
        let depth: Int
        var titleSearchBytes = 0
        if countedBound <= maximumDepth || count.namesTagWithModeDependentRawText {
            depth = countedBound
        } else {
            var scanner = TokenizingScanner(bytes: bytes, limit: limit)
            depth = min(scanner.run(), countedBound)
            titleSearchBytes = scanner.titleSearchBytes
        }
        let (treeWork, overflow) = depth.multipliedReportingOverflow(by: count.tagCount)
        return ParseCost(
            depth: depth,
            treeWork: overflow ? .max : treeWork,
            titleSearchBytes: titleSearchBytes
        )
    }
}

/// Carries a parse to the measuring thread and its outcome back.
/// `@unchecked Sendable`: the caller sets `work` (and `parsed`, for a
/// release) before the thread starts and reads the fields again only after
/// `finished.wait()`, which the thread signals after its last write.
private final class MeasuringThreadHandOff<Parsed>: @unchecked Sendable {
    var work: ((MeasuringThreadHandOff<Parsed>) -> Void)?
    var parsed: Parsed?
    var error: Error?
    let finished = DispatchSemaphore(value: 0)

    func run() {
        work?(self)
        work = nil
        finished.signal()
    }
}

// MARK: - Tag names

private enum ScannedTagName {
    static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }

    static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    static func isTokenizerWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    /// SwiftSoup's tag-name delimiters other than NUL, which it replaces
    /// and keeps reading the name after.
    static func endsTagName(_ byte: UInt8) -> Bool {
        isTokenizerWhitespace(byte) || byte == 0x2F || byte == 0x3E
    }

    /// Elements SwiftSoup always inserts empty, never pushing them. Kept to
    /// the ones the tree builder's handlers insert empty themselves; any
    /// other name is counted as an element that can hold children.
    static let voidNames: Set<[UInt8]> = Set([
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "hr", "img", "input",
        "keygen", "link", "meta", "param", "source", "track", "wbr"
    ].map { Array($0.utf8) })

    /// Never pushed again once the document has them.
    static let documentNames: Set<[UInt8]> = Set(["html", "head", "body"].map { Array($0.utf8) })

    /// Names after which SwiftSoup reads raw text in some insertion modes
    /// and markup in others, which a scan of the bytes cannot tell apart:
    /// inside `select` it ignores `style` and `title`, in a frameset most
    /// start tags, and a `noscript` is raw text in the head but markup in the
    /// body (measured).
    static let namesWithModeDependentRawText: Set<[UInt8]> = Set(["select", "frameset", "noscript"].map { Array($0.utf8) })

    static let td = Array("td".utf8)
    static let th = Array("th".utf8)
    static let tr = Array("tr".utf8)
    static let p = Array("p".utf8)
    static let li = Array("li".utf8)
    static let dd = Array("dd".utf8)
    static let dt = Array("dt".utf8)
    static let option = Array("option".utf8)
    static let optgroup = Array("optgroup".utf8)
    static let tableSections: Set<[UInt8]> = Set(["tbody", "thead", "tfoot"].map { Array($0.utf8) })
    static let headings: Set<[UInt8]> = Set(["h1", "h2", "h3", "h4", "h5", "h6"].map { Array($0.utf8) })

    /// Start tags that close a `p` in button scope (HTML's list; SwiftSoup's
    /// `InBodyStartPClosers` plus the others whose handlers close one).
    static let closesParagraph: Set<[UInt8]> = Set([
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div",
        "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "main", "menu",
        "nav", "ol", "p", "section", "summary", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
        "listing", "form", "li", "dd", "dt", "plaintext", "xmp"
    ].map { Array($0.utf8) })

    /// Raw text SwiftSoup's tree builder switches its tokenizer to after
    /// these start tags (`textarea`, `xmp`, `iframe` and `noembed` it parses
    /// as markup; measured).
    enum RawText {
        case rcdataOrRawtext
        case scriptData
        case plaintext
    }

    private static let rcdataOrRawtextNames: Set<[UInt8]> = Set(["title", "style", "noframes"].map { Array($0.utf8) })
    private static let script = Array("script".utf8)
    private static let plaintext = Array("plaintext".utf8)

    static func rawText(after name: [UInt8], selfClosing: Bool) -> RawText? {
        if name == plaintext {
            // `<plaintext/>` too (measured).
            return .plaintext
        }
        // A self-closing `<style/>` is an empty element, and what follows
        // it is markup (measured).
        guard !selfClosing else { return nil }
        if rcdataOrRawtextNames.contains(name) {
            return .rcdataOrRawtext
        }
        return name == script ? .scriptData : nil
    }

    /// How many levels a start tag can add: itself and what the tree
    /// builder may insert above it.
    static func weight(of name: [UInt8]) -> Int {
        if voidNames.contains(name) || documentNames.contains(name) {
            return 0
        }
        if name == td || name == th {
            return 3
        }
        if name == tr {
            return 2
        }
        return 1
    }
}

// MARK: - First scan

/// Counts every `<` followed by an ASCII letter as an element that never
/// closes. Tokenizer state does not matter to it, so nothing a sender writes
/// can make it count less than the tree holds.
private struct StartTagCount {
    /// Longer than any name `ScannedTagName` gives a meaning (`plaintext`).
    private static let nameLengthRead = 17

    private(set) var weight = 0
    /// Every `<` or `</` followed by an ASCII letter.
    private(set) var tagCount = 0
    private(set) var namesTagWithModeDependentRawText = false

    init(bytes: UnsafeBufferPointer<UInt8>) {
        let count = bytes.count
        var index = 0
        while index < count {
            guard bytes[index] == 0x3C else {
                index += 1
                continue
            }
            let nameStart = index + 1
            guard nameStart < count, ScannedTagName.isASCIIAlpha(bytes[nameStart]) else {
                if nameStart + 1 < count, bytes[nameStart] == 0x2F, ScannedTagName.isASCIIAlpha(bytes[nameStart + 1]) {
                    tagCount += 1
                }
                index += 1
                continue
            }
            tagCount += 1
            // At most `nameLengthRead` bytes: every name the scan looks up
            // is shorter, so a longer one counts as unknown either way. The
            // scan goes on from the next byte, not past the name, so reading
            // names to their end was quadratic on `<a<a<a…` with no
            // delimiter (`testEstimatedDepth_delimiterlessTagRun_isLinear`).
            var nameEnd = nameStart
            var name: [UInt8] = []
            while nameEnd < count,
                  nameEnd - nameStart < Self.nameLengthRead,
                  !ScannedTagName.endsTagName(bytes[nameEnd]) {
                name.append(ScannedTagName.lowercasedASCII(bytes[nameEnd]))
                nameEnd += 1
            }
            weight += ScannedTagName.weight(of: name)
            if ScannedTagName.namesWithModeDependentRawText.contains(name) {
                namesTagWithModeDependentRawText = true
            }
            index = nameStart
        }
    }
}

// MARK: - Second scan

/// Tokenizes as SwiftSoup 2.13.5 does and keeps a stack of the elements
/// that may still be open.
private struct TokenizingScanner {
    private struct OpenElement {
        let name: [UInt8]
        let weight: Int
    }

    private struct Tag {
        let name: [UInt8]
        let isEndTag: Bool
        let selfClosing: Bool
        /// Index after the tag's `>`, or nil when the input ended inside it.
        let end: Int?
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private let count: Int
    private let limit: Int
    private var stack: [OpenElement] = []
    private var openWeight = 0
    private var deepestOpenWeight = 0
    /// What SwiftSoup's searches for a title's end tag read
    /// (`EmailDOMParseAdmission.ParseCost`).
    private(set) var titleSearchBytes = 0
    /// The next `</title` and `</TITLE` at or after the last position asked
    /// about (`count` for none), or -1 before the first ask.
    private var nextLowercaseTitleEndTag = -1
    private var nextUppercaseTitleEndTag = -1

    init(bytes: UnsafeBufferPointer<UInt8>, limit: Int) {
        self.bytes = bytes
        self.count = bytes.count
        self.limit = limit
    }

    private var bound: Int {
        deepestOpenWeight + EmailDOMParseAdmission.enclosingNodeCount + EmailDOMParseAdmission.leafAllowance
    }

    mutating func run() -> Int {
        var index = 0
        while index < count {
            guard bytes[index] == 0x3C else {
                index += 1
                continue
            }
            guard let next = markup(at: index) else {
                break
            }
            index = next
            if bound > limit {
                break
            }
        }
        return bound
    }

    /// Handles the markup starting at the `<` at `index`; returns where data
    /// resumes, or nil when nothing after it can open an element.
    private mutating func markup(at index: Int) -> Int? {
        let next = index + 1
        guard next < count else { return nil }
        let byte = bytes[next]

        if ScannedTagName.isASCIIAlpha(byte) {
            let tag = readTag(nameStart: next, isEndTag: false)
            guard let end = tag.end else { return nil }
            openElement(named: tag.name)
            switch ScannedTagName.rawText(after: tag.name, selfClosing: tag.selfClosing) {
            case .none:
                return end
            case .rcdataOrRawtext:
                return endOfRawText(named: tag.name, from: end)
            case .scriptData:
                return endOfScriptData(from: end)
            case .plaintext:
                return nil
            }
        }

        switch byte {
        case 0x2F: // "</"
            let nameStart = next + 1
            guard nameStart < count else { return nil }
            let first = bytes[nameStart]
            if ScannedTagName.isASCIIAlpha(first) {
                let tag = readTag(nameStart: nameStart, isEndTag: true)
                guard let end = tag.end else { return nil }
                closeElement(named: tag.name)
                return end
            }
            if first == 0x3E {
                return nameStart + 1
            }
            return endOfBogusComment(from: nameStart)
        case 0x21: // "<!"
            return endOfMarkupDeclaration(from: next + 1)
        case 0x3F: // "<?"
            return endOfBogusComment(from: next)
        default:
            return next
        }
    }

    // MARK: Tree

    private mutating func openElement(named name: [UInt8]) {
        let weight = ScannedTagName.weight(of: name)
        guard weight > 0 else { return }
        closeImpliedElements(before: name)
        stack.append(OpenElement(name: name, weight: weight))
        openWeight += weight
        deepestOpenWeight = max(deepestOpenWeight, openWeight)
    }

    private mutating func closeElement(named name: [UInt8]) {
        if stack.last?.name == name {
            popInnermost()
        }
    }

    private mutating func popInnermost() {
        guard let element = stack.popLast() else { return }
        openWeight -= element.weight
    }

    private func innermostIs(_ name: [UInt8]) -> Bool {
        stack.last?.name == name
    }

    private func innermostIs(in names: Set<[UInt8]>) -> Bool {
        stack.last.map { names.contains($0.name) } ?? false
    }

    /// Closes the innermost element where the tree builder always closes it
    /// before inserting `name`. Each rule pops only an element that is the
    /// innermost one, where the builder's own rule (close a `p` in button
    /// scope, close the cell, and so on) is certain to close it too.
    private mutating func closeImpliedElements(before name: [UInt8]) {
        typealias N = ScannedTagName
        if N.closesParagraph.contains(name), innermostIs(N.p) {
            popInnermost()
        }
        if N.headings.contains(name), innermostIs(in: N.headings) {
            popInnermost()
        }
        if name == N.li, innermostIs(N.li) {
            popInnermost()
        }
        if name == N.dd || name == N.dt, innermostIs(N.dd) || innermostIs(N.dt) {
            popInnermost()
        }
        if name == N.td || name == N.th, innermostIs(N.td) || innermostIs(N.th) {
            popInnermost()
        }
        if name == N.tr || N.tableSections.contains(name) {
            if innermostIs(N.td) || innermostIs(N.th) {
                popInnermost()
            }
            if innermostIs(N.tr) {
                popInnermost()
            }
            if N.tableSections.contains(name), innermostIs(in: N.tableSections) {
                popInnermost()
            }
        }
        // Outside `select` an `optgroup` closes only an `option`, never
        // another `optgroup` (inside `select` the first scan decides).
        if name == N.option || name == N.optgroup, innermostIs(N.option) {
            popInnermost()
        }
    }

    // MARK: Tags

    /// Reads a tag from the first letter of its name to the end of its `>`,
    /// through the same states as SwiftSoup's tokenizer, so a `>` inside a
    /// quoted attribute value does not end it.
    private func readTag(nameStart: Int, isEndTag: Bool) -> Tag {
        var index = nameStart
        var name: [UInt8] = []
        // NUL is replaced and the name goes on; keep it so the name stays
        // unknown, as SwiftSoup's does.
        while index < count, !ScannedTagName.endsTagName(bytes[index]) {
            name.append(ScannedTagName.lowercasedASCII(bytes[index]))
            index += 1
        }

        // SwiftSoup's fast path right after the name: optional whitespace,
        // then ">" or "/" (optional whitespace) ">", the second self-closing.
        var probe = skipWhitespace(from: index)
        if probe < count, bytes[probe] == 0x3E {
            return Tag(name: name, isEndTag: isEndTag, selfClosing: false, end: probe + 1)
        }
        if probe < count, bytes[probe] == 0x2F {
            probe = skipWhitespace(from: probe + 1)
            if probe < count, bytes[probe] == 0x3E {
                return Tag(name: name, isEndTag: isEndTag, selfClosing: true, end: probe + 1)
            }
        }

        let (end, selfClosing) = endOfAttributes(from: index)
        return Tag(name: name, isEndTag: isEndTag, selfClosing: selfClosing, end: end)
    }

    private func skipWhitespace(from start: Int) -> Int {
        var index = start
        while index < count, ScannedTagName.isTokenizerWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private enum AttributeState {
        case beforeName
        case name
        case afterName
        case beforeValue
        case quotedValue(UInt8)
        case unquotedValue
        case afterQuotedValue
        case selfClosing
    }

    /// From the byte after a tag name to the index after the tag's `>` (nil
    /// at the end of the input) and whether `/>` closed it.
    private func endOfAttributes(from start: Int) -> (Int?, Bool) {
        var index = start
        var state = AttributeState.beforeName
        // The name ended at whitespace, "/" or ">".
        if index < count, bytes[index] == 0x2F {
            state = .selfClosing
            index += 1
        }

        while index < count {
            let byte = bytes[index]
            switch state {
            case .beforeName:
                if ScannedTagName.isTokenizerWhitespace(byte) {
                    index += 1
                } else if byte == 0x2F {
                    state = .selfClosing
                    index += 1
                } else if byte == 0x3E {
                    return (index + 1, false)
                } else {
                    // Quotes, "<", "=" and NUL start a name here as any
                    // other byte does.
                    state = .name
                    index += 1
                }
            case .name:
                if ScannedTagName.isTokenizerWhitespace(byte) {
                    state = .afterName
                    index += 1
                } else if byte == 0x2F {
                    state = .selfClosing
                    index += 1
                } else if byte == 0x3D {
                    state = .beforeValue
                    index += 1
                } else if byte == 0x3E {
                    return (index + 1, false)
                } else {
                    index += 1
                }
            case .afterName:
                if ScannedTagName.isTokenizerWhitespace(byte) {
                    index += 1
                } else if byte == 0x2F {
                    state = .selfClosing
                    index += 1
                } else if byte == 0x3D {
                    state = .beforeValue
                    index += 1
                } else if byte == 0x3E {
                    return (index + 1, false)
                } else {
                    state = .name
                    index += 1
                }
            case .beforeValue:
                if ScannedTagName.isTokenizerWhitespace(byte) {
                    index += 1
                } else if byte == 0x22 || byte == 0x27 {
                    state = .quotedValue(byte)
                    index += 1
                } else if byte == 0x3E {
                    return (index + 1, false)
                } else {
                    state = .unquotedValue
                    index += 1
                }
            case let .quotedValue(quote):
                if byte == quote {
                    state = .afterQuotedValue
                }
                index += 1
            case .unquotedValue:
                if ScannedTagName.isTokenizerWhitespace(byte) {
                    state = .beforeName
                    index += 1
                } else if byte == 0x3E {
                    return (index + 1, false)
                } else {
                    index += 1
                }
            case .afterQuotedValue:
                if ScannedTagName.isTokenizerWhitespace(byte) {
                    state = .beforeName
                    index += 1
                } else if byte == 0x2F {
                    state = .selfClosing
                    index += 1
                } else if byte == 0x3E {
                    return (index + 1, false)
                } else {
                    // Reconsumed as the start of the next attribute.
                    state = .beforeName
                }
            case .selfClosing:
                if byte == 0x3E {
                    return (index + 1, true)
                }
                // Reconsumed before an attribute name.
                state = .beforeName
            }
        }
        return (nil, false)
    }

    // MARK: Comments and declarations

    private func firstIndex(of byte: UInt8, from start: Int) -> Int? {
        var index = start
        while index < count {
            if bytes[index] == byte {
                return index
            }
            index += 1
        }
        return nil
    }

    private func matches(_ literal: [UInt8], at index: Int, ignoringCase: Bool = false) -> Bool {
        guard index + literal.count <= count else { return false }
        for offset in 0..<literal.count {
            let byte = bytes[index + offset]
            let candidate = ignoringCase ? ScannedTagName.lowercasedASCII(byte) : byte
            if candidate != literal[offset] {
                return false
            }
        }
        return true
    }

    /// A bogus comment runs to the first `>`.
    private func endOfBogusComment(from start: Int) -> Int? {
        firstIndex(of: 0x3E, from: start).map { $0 + 1 }
    }

    /// From the byte after `<!`.
    private func endOfMarkupDeclaration(from start: Int) -> Int? {
        if matches(Self.commentOpenRest, at: start) {
            return endOfComment(from: start + 2)
        }
        if matches(Self.doctype, at: start, ignoringCase: true) {
            // A doctype ends at its first ">", quoted identifiers included
            // (measured).
            return endOfBogusComment(from: start)
        }
        if matches(Self.cdataOpenRest, at: start) {
            // SwiftSoup reads CDATA anywhere, not only in foreign content.
            var index = start + 7
            while index + 2 < count {
                if bytes[index] == 0x5D, bytes[index + 1] == 0x5D, bytes[index + 2] == 0x3E {
                    return index + 3
                }
                index += 1
            }
            return nil
        }
        return endOfBogusComment(from: start)
    }

    /// From the byte after `<!--`. A run of `-` then `>` ends it at once
    /// (`<!-->`, `<!--->`). Otherwise the first `-->` or `--!>` after that
    /// run does: SwiftSoup's comment start states stay put on a `-`, so the
    /// run's dashes never begin an ending (`<!----!>` does not end).
    private func endOfComment(from start: Int) -> Int? {
        var index = start
        while index < count, bytes[index] == 0x2D {
            index += 1
        }
        if index < count, bytes[index] == 0x3E {
            return index + 1
        }
        while index + 2 < count {
            if bytes[index] == 0x2D, bytes[index + 1] == 0x2D {
                if bytes[index + 2] == 0x3E {
                    return index + 3
                }
                if bytes[index + 2] == 0x21, index + 3 < count, bytes[index + 3] == 0x3E {
                    return index + 4
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: Raw text

    /// Whether `</name` followed by whitespace, `/` or `>` starts at `index`:
    /// the only end tag the raw text states accept.
    private func isAppropriateEndTag(named name: [UInt8], at index: Int) -> Bool {
        guard index + 2 + name.count < count,
              bytes[index] == 0x3C,
              bytes[index + 1] == 0x2F,
              matches(name, at: index + 2, ignoringCase: true) else {
            return false
        }
        return ScannedTagName.endsTagName(bytes[index + 2 + name.count])
    }

    /// When `</name` at `index` is followed by a byte that neither ends a tag
    /// name nor continues it (`</style<`, `</script"`), where the raw text
    /// goes on: after that byte, or that character outside ASCII. SwiftSoup's
    /// RAWTEXT and script data states take it as text with the end tag
    /// (`handleDataEndTag`), so a `<` there never starts the next end tag:
    /// `<style></style</style x>` is still raw text after its second
    /// `</style`. Its RCDATA state (`title`) gives the byte back instead.
    private func endAfterEndTagFollowedByText(named name: [UInt8], at index: Int) -> Int? {
        let followingIndex = index + 2 + name.count
        guard followingIndex < count,
              bytes[index] == 0x3C,
              bytes[index + 1] == 0x2F,
              matches(name, at: index + 2, ignoringCase: true) else {
            return nil
        }
        let following = bytes[followingIndex]
        guard !ScannedTagName.endsTagName(following), !ScannedTagName.isASCIIAlpha(following) else {
            return nil
        }
        let characterLength: Int
        switch following {
        case 0xF0...: characterLength = 4
        case 0xE0...: characterLength = 3
        case 0xC0...: characterLength = 2
        default: characterLength = 1
        }
        return min(count, followingIndex + characterLength)
    }

    /// Skips RCDATA or RAWTEXT and handles its end tag; nil at the end of
    /// the input.
    ///
    /// SwiftSoup leaves the spec for a `title` (its one RCDATA element): at
    /// a `<` and an ASCII letter, when neither `</title` nor `</TITLE` occurs
    /// from there on (mixed case does not count), it closes the title and
    /// reads markup again from that `<`, rather than taking the rest of the
    /// input as the title's text.
    private mutating func endOfRawText(named name: [UInt8], from start: Int) -> Int? {
        let endsAtStartTagWithoutEndTag = name == Self.title
        var index = start
        while index < count {
            if bytes[index] == 0x3C {
                if isAppropriateEndTag(named: name, at: index) {
                    return endTag(at: index)
                }
                if !endsAtStartTagWithoutEndTag,
                   let resume = endAfterEndTagFollowedByText(named: name, at: index) {
                    index = resume
                    continue
                }
                if endsAtStartTagWithoutEndTag,
                   index + 1 < count,
                   ScannedTagName.isASCIIAlpha(bytes[index + 1]) {
                    countTitleEndTagSearch(from: index + 1)
                    if lastTitleEndTagStart < index + 1 {
                        closeElement(named: name)
                        return index
                    }
                }
            }
            index += 1
        }
        return nil
    }

    /// Adds what SwiftSoup's `containsIgnoreCase` reads from `position`: up
    /// to the next `</title`, or else all the rest and then up to the next
    /// `</TITLE` (it tries those two spellings, in that order).
    private mutating func countTitleEndTagSearch(from position: Int) {
        let lowercase = Self.nextOccurrence(
            of: Self.lowercaseTitleEndTag, in: bytes, from: position, cursor: &nextLowercaseTitleEndTag
        )
        var searched = lowercase - position
        if lowercase == count {
            let uppercase = Self.nextOccurrence(
                of: Self.uppercaseTitleEndTag, in: bytes, from: position, cursor: &nextUppercaseTitleEndTag
            )
            searched += uppercase - position
        }
        titleSearchBytes = titleSearchBytes.addingReportingOverflow(searched).overflow ? .max : titleSearchBytes + searched
    }

    /// The first index at or after `position` where `pattern` starts, or
    /// `count`. Positions asked about only grow, so the cursor makes all the
    /// searches of one scan linear together.
    private static func nextOccurrence(
        of pattern: [UInt8],
        in bytes: UnsafeBufferPointer<UInt8>,
        from position: Int,
        cursor: inout Int
    ) -> Int {
        if cursor >= position {
            return cursor
        }
        var index = max(position, cursor)
        search: while index + pattern.count <= bytes.count {
            for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
                index += 1
                continue search
            }
            cursor = index
            return index
        }
        cursor = bytes.count
        return bytes.count
    }

    private static let title = Array("title".utf8)
    private static let lowercaseTitleEndTag = Array("</title".utf8)
    private static let uppercaseTitleEndTag = Array("</TITLE".utf8)

    /// Where the last `</title` or `</TITLE` starts, or -1.
    private lazy var lastTitleEndTagStart: Int = {
        var index = count - Self.lowercaseTitleEndTag.count
        while index >= 0 {
            if matches(Self.lowercaseTitleEndTag, at: index) || matches(Self.uppercaseTitleEndTag, at: index) {
                return index
            }
            index -= 1
        }
        return -1
    }()

    private mutating func endTag(at index: Int) -> Int? {
        let tag = readTag(nameStart: index + 2, isEndTag: true)
        guard let end = tag.end else { return nil }
        closeElement(named: tag.name)
        return end
    }

    private enum ScriptState {
        case data
        case escaped
        case escapedDash
        case escapedDashDash
        case doubleEscaped
        case doubleEscapedDash
        case doubleEscapedDashDash
    }

    private static let script = Array("script".utf8)
    private static let commentOpen = Array("<!--".utf8)
    private static let commentOpenRest = Array("--".utf8)
    private static let doctype = Array("doctype".utf8)
    private static let cdataOpenRest = Array("[CDATA[".utf8)

    /// Skips script data, including its `<!--` escape and `<script` double
    /// escape states, and handles its end tag.
    private mutating func endOfScriptData(from start: Int) -> Int? {
        var index = start
        var state = ScriptState.data
        while index < count {
            let byte = bytes[index]
            switch state {
            case .data, .escaped, .escapedDash, .escapedDashDash:
                if byte == 0x3C {
                    if isAppropriateEndTag(named: Self.script, at: index) {
                        return endTag(at: index)
                    }
                    if let resume = endAfterEndTagFollowedByText(named: Self.script, at: index) {
                        state = state == .data ? .data : .escaped
                        index = resume
                        continue
                    }
                    if state == .data {
                        if matches(Self.commentOpen, at: index) {
                            state = .escapedDashDash
                            index += 4
                        } else {
                            index += 1
                        }
                        continue
                    }
                    if let afterName = scriptNameEnd(after: index + 1) {
                        state = .doubleEscaped
                        index = afterName
                    } else {
                        state = .escaped
                        index += 1
                    }
                    continue
                }
                if state == .data {
                    index += 1
                    continue
                }
                if byte == 0x2D {
                    state = state == .escaped ? .escapedDash : .escapedDashDash
                } else if byte == 0x3E, state == .escapedDashDash {
                    state = .data
                } else {
                    state = .escaped
                }
                index += 1
            case .doubleEscaped, .doubleEscapedDash, .doubleEscapedDashDash:
                if byte == 0x3C {
                    if index + 1 < count, bytes[index + 1] == 0x2F,
                       let afterName = scriptNameEnd(after: index + 2) {
                        state = .escaped
                        index = afterName
                    } else {
                        state = .doubleEscaped
                        index += 1
                    }
                    continue
                }
                if byte == 0x2D {
                    state = state == .doubleEscaped ? .doubleEscapedDash : .doubleEscapedDashDash
                } else if byte == 0x3E, state == .doubleEscapedDashDash {
                    state = .data
                } else {
                    state = .doubleEscaped
                }
                index += 1
            }
        }
        return nil
    }

    /// When the letters at `index` are exactly `script` followed by
    /// whitespace, `/` or `>`, the index after that delimiter (the double
    /// escape start and end states consume it). Lowercase only: SwiftSoup
    /// compares the letters as written, so `<SCRIPT>` neither starts nor
    /// ends a double escape (measured).
    private func scriptNameEnd(after index: Int) -> Int? {
        let delimiterIndex = index + Self.script.count
        guard delimiterIndex < count,
              matches(Self.script, at: index),
              ScannedTagName.endsTagName(bytes[delimiterIndex]) else {
            return nil
        }
        return delimiterIndex + 1
    }
}
