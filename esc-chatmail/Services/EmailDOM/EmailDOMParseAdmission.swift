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
///   by an end tag naming the innermost one, by a start tag that always
///   closes the innermost one (`<p>` closing a `p`, `<td>` a `td`), or by an
///   end tag whose handler pops everything above its element (`</td>` over
///   a `<font>` left open), but only where that element is certainly open:
///   every tag after which the tree builder may have closed something the
///   scan still holds marks what it may have closed as no longer certain,
///   and a table part pushed outside a certainly open table, or anything
///   self-closing, is never certain (SwiftSoup ignores or closes those at
///   once). Every other closing the tree builder might do is ignored, which
///   can only over-count: a formatting element stays counted after an end
///   tag passes over it, as the tree builder may reconstruct it any number
///   of times (`<p><b>x</p>` on 1,000 lines nests 1,000 deep). Tags the
///   builder may add on its own are counted with the one that implies them
///   (`td` as three: `tbody`, `tr`, `td`).
///   SwiftSoup reads raw text after some tags in one insertion mode and
///   markup in another (`style` inside `select`, anything in a frameset, a
///   `noscript` in the head), so once the second scan reads a `select` or
///   `frameset` start tag, or a `noscript` one before the head has ended
///   where it cannot be certain the tree builder is still in the head, the
///   first scan's count decides. Up to that tag the second scan reads as
///   SwiftSoup does, so a name inside a comment or an attribute, or a
///   `noscript` in the body, changes nothing. A `noscript` read while the
///   builder is certainly in the head (a document with nothing before it
///   but whitespace, comments, declarations and the head's own tags) is
///   followed: SwiftSoup reads every tag in it as text but `style`,
///   `noframes` and its `</noscript>`.
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
        try admittedParse(html, readsHead: false, rootDepth: 1, roots: { [$0] }) {
            try SwiftSoup.parseBodyFragment(html)
        }
    }

    /// Parses a fragment in `context`, unless it is nested too deeply
    /// (`EmailDOMParseRefusal`). The nodes are measured as
    /// `EmailDOMFragmentParser` places them, under a document's `body`.
    static func parseFragment(_ html: String, context: Element) throws -> [Node] {
        try admittedParse(
            html,
            isTableContextFragment: true,
            readsHead: false,
            rootDepth: enclosingNodeCount + 1,
            roots: { $0 }
        ) {
            try Parser.parseFragment(html, context, [UInt8]())
        }
    }

    /// Whether `html` would be admitted, without keeping the tree.
    static func admit(_ html: String) throws {
        _ = try parseDocument(html)
    }

    private static func admittedParse<Parsed>(
        _ html: String,
        isTableContextFragment: Bool = false,
        readsHead: Bool = true,
        rootDepth: Int,
        roots: @escaping (Parsed) -> [Node],
        parse: @escaping () throws -> Parsed
    ) throws -> Parsed {
        let cost = estimatedCost(
            of: html,
            limit: maximumBoundForMeasuredParse,
            isTableContextFragment: isTableContextFragment,
            readsHead: readsHead
        )
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
    /// bounded as well as depth. Each term is an upper bound on one of
    /// SwiftSoup 2.13.5's super-linear steps (all measured in a Release
    /// build by review of PR 453):
    /// - `treeWork`, the depth bound times every `<`: most tags, and every
    ///   run of text, search the open elements (`<span>` × 8,000 then
    ///   200,000 `</x>` took 83 s; `<b>`, 6,000 `<div>`s and 400,000 `x<?>`
    ///   took 55 s, `<?>` splitting the text with no tag). Added to it, the
    ///   rebuilding of formatting elements the tree builder has closed but
    ///   keeps (`reconstructFormattingElements`), at every token: a search
    ///   of the open elements for each one that may be off the stack (at
    ///   most three of one name and attributes, as the list keeps), and its
    ///   attribute count squared for copying its attributes. Where the
    ///   second scan cannot follow the markup (`readModeDependentTag`),
    ///   every earlier formatting tag counts at every token, each with the
    ///   most attributes any formatting tag could hold
    ///   (`FormattingAttributeBound`).
    /// - `titleSearchBytes`: inside a `title`, SwiftSoup searches the rest of
    ///   the input for its end tag at every `<` and letter
    ///   (`RcdataLessthanSign`; `<title>` then 640 KB of `<br ` took 31 s).
    ///   Computed from the bytes alone (`TitleSearchCost`), so no reading of
    ///   the markup can hide one.
    /// - `formattingCompareWork`: each formatting start tag is compared with
    ///   the active formatting elements, attribute by attribute
    ///   (`pushActiveFormattingElements`; 6,000 `<b>`s of 100 attributes
    ///   took 50 s). Every element in that list is open or was closed by an
    ///   end tag that crossed it, which the second scan keeps counting, so
    ///   the scan charges, per formatting start tag, one comparison for each
    ///   formatting element it holds and the tag's length for each of the
    ///   same name. A body whose markup the second scan cannot follow
    ///   (`readModeDependentTag`) is charged as if every earlier
    ///   formatting tag were held, at the body's whole length.
    /// - `childMoveWork`: the adoption agency (a formatting end tag that is
    ///   not the innermost element, or an `<a>` while one is held) moves
    ///   every child of its furthest block, one at a time, and each move
    ///   takes the first child out of the block's list and renumbers the
    ///   rest (`removeChild(at: 0)`, `reindexChildren`), so a
    ///   block of n children costs n² (`<b><div>` and 100,000 `<br>`s then
    ///   `</b>` took 14 s, a megabyte 153 s). The second scan counts the
    ///   nodes each held element may have been given (`childPrefix`) and
    ///   charges, at each such tag, the square of the most any element that
    ///   may be the furthest block holds, once for each formatting element
    ///   of that name the agency may go through. Where the second scan
    ///   cannot follow the markup, every node of the body is counted in one
    ///   block.
    struct ParseCost: Equatable {
        let depth: Int
        let treeWork: Int
        let titleSearchBytes: Int
        let formattingCompareWork: Int
        let childMoveWork: Int

        /// The refusal past one of the work limits.
        var excessWork: EmailDOMParseRefusal? {
            if treeWork > EmailDOMParseAdmission.maximumTreeWork {
                return .tooCostlyToParse(work: treeWork, limit: EmailDOMParseAdmission.maximumTreeWork)
            }
            if titleSearchBytes > EmailDOMParseAdmission.maximumTitleSearchBytes {
                return .tooCostlyToParse(work: titleSearchBytes, limit: EmailDOMParseAdmission.maximumTitleSearchBytes)
            }
            if formattingCompareWork > EmailDOMParseAdmission.maximumFormattingCompareWork {
                return .tooCostlyToParse(
                    work: formattingCompareWork,
                    limit: EmailDOMParseAdmission.maximumFormattingCompareWork
                )
            }
            if childMoveWork > EmailDOMParseAdmission.maximumChildMoveWork {
                return .tooCostlyToParse(work: childMoveWork, limit: EmailDOMParseAdmission.maximumChildMoveWork)
            }
            return nil
        }
    }

    /// About a second of the stack searches in a Release build (measured at
    /// about 30 million depth × tag units a second).
    static let maximumTreeWork = 50_000_000
    /// About half a second of byte comparisons (measured at about two
    /// billion a second).
    static let maximumTitleSearchBytes = 1_000_000_000
    /// About half a second of attribute comparisons (measured at about two
    /// hundred million bytes a second).
    static let maximumFormattingCompareWork = 100_000_000
    /// About half a second of child moves (measured at about eight hundred
    /// million children² a second).
    static let maximumChildMoveWork = 400_000_000

    /// `isTableContextFragment`: parsed in a table part's context
    /// (`EmailDOMFragmentParser`), where SwiftSoup ignores table parts that
    /// a document would insert. `readsHead`: parsed as a document, which
    /// starts in the head; a fragment starts in the body.
    static func estimatedCost(
        of html: String,
        limit: Int = .max,
        isTableContextFragment: Bool = false,
        readsHead: Bool = true
    ) -> ParseCost {
        let bytes = html.utf8
        let readsHead = readsHead && !isTableContextFragment
        if let cost = bytes.withContiguousStorageIfAvailable({ buffer in
            estimate(in: buffer, limit: limit, isTableContextFragment: isTableContextFragment, readsHead: readsHead)
        }) {
            return cost
        }
        return Array(bytes).withUnsafeBufferPointer {
            estimate(in: $0, limit: limit, isTableContextFragment: isTableContextFragment, readsHead: readsHead)
        }
    }

    /// The second scan alone, without the first scan's shortcut or its
    /// rule for mode-dependent tags. Exposed for the comparison
    /// tests; only `estimatedDepth(of:limit:)` may route a parse.
    static func tokenizedDepthEstimate(
        of html: String,
        isTableContextFragment: Bool = false,
        readsHead: Bool = true
    ) -> Int {
        followedTokenizedDepthEstimate(of: html, isTableContextFragment: isTableContextFragment, readsHead: readsHead).depth
    }

    /// The second scan's depth, and whether it followed the markup to the
    /// end (it read no `readModeDependentTag`), where only then is the
    /// depth a bound on its own. For the comparison tests.
    static func followedTokenizedDepthEstimate(
        of html: String,
        isTableContextFragment: Bool = false,
        readsHead: Bool = true
    ) -> (depth: Int, followed: Bool) {
        let bytes = Array(html.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            var scanner = TokenizingScanner(
                bytes: buffer,
                limit: .max,
                isTableContextFragment: isTableContextFragment,
                readsHead: readsHead && !isTableContextFragment
            )
            let depth = scanner.run()
            return (depth, !scanner.readModeDependentTag)
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
    private static func estimate(
        in bytes: UnsafeBufferPointer<UInt8>,
        limit: Int,
        isTableContextFragment: Bool,
        readsHead: Bool
    ) -> ParseCost {
        let fixed = enclosingNodeCount + leafAllowance
        let count = StartTagCount(bytes: bytes)
        let countedBound = count.weight + fixed
        // The second scan always runs, for its costs; its depth counts only
        // where the first scan's does not already admit the parse here.
        var scanner = TokenizingScanner(
            bytes: bytes,
            limit: limit,
            isTableContextFragment: isTableContextFragment,
            readsHead: readsHead
        )
        let tokenizedDepth = scanner.run()
        let depth: Int
        let formattingCompareWork: Int
        let rebuildWork: Int
        let childMoveWork: Int
        if scanner.readModeDependentTag {
            depth = countedBound
            formattingCompareWork = Saturating.add(
                Saturating.multiply(count.formattingTagCount, count.formattingTagCount * 16),
                Saturating.multiply(count.formattingTagCount, bytes.count)
            )
            // Every earlier formatting tag may be off the stack at every
            // token, with as many attributes as any of them may have.
            let attributes = FormattingAttributeBound.maximumAttributeCount(in: bytes, nameStarts: count.formattingNameStarts)
            rebuildWork = Saturating.multiply(
                Saturating.multiply(count.formattingTagsAcrossTokens, 2),
                Saturating.add(depth, TokenizingScanner.rebuildCost(attributeCount: attributes))
            )
            // Every node of the body in one block: each `<` gives an element
            // at most the run of text before it and itself, each pass of the
            // adoption agency an adopter and a moved block, at most one pass
            // for each formatting start tag, and foster parenting a rebuilt
            // copy of each formatting element before it at each token. A
            // block's children are moved together once, so this bounds the
            // sum of the squares too.
            if count.mayRunAdoptionAgency {
                let nodes = Saturating.add(
                    Saturating.add(Saturating.multiply(count.tokenCount, 2), 1),
                    Saturating.add(
                        Saturating.multiply(count.formattingTagCount, 2),
                        Saturating.multiply(count.formattingTagsAcrossTokens, 2)
                    )
                )
                childMoveWork = Saturating.multiply(nodes, nodes)
            } else {
                childMoveWork = 0
            }
        } else {
            depth = countedBound <= maximumDepth ? countedBound : min(tokenizedDepth, countedBound)
            formattingCompareWork = scanner.formattingCompareWork
            rebuildWork = Saturating.add(
                Saturating.multiply(scanner.rebuildCandidatesAcrossTokens, depth),
                scanner.rebuildCostAcrossTokens
            )
            childMoveWork = scanner.childMoveWork
        }
        return ParseCost(
            depth: depth,
            treeWork: Saturating.add(Saturating.multiply(depth, count.tokenCount), rebuildWork),
            titleSearchBytes: TitleSearchCost.bytesRead(in: bytes),
            formattingCompareWork: formattingCompareWork,
            childMoveWork: childMoveWork
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
    /// other name is counted as an element that can hold children. A
    /// `command` is inserted empty in the body too (`InBodyStartToHead`,
    /// then the head's `baseEtc`): held as open, its `</command>` dropped
    /// the children counted on it.
    static let voidNames: Set<[UInt8]> = Set([
        "area", "base", "basefont", "bgsound", "br", "col", "command", "embed", "hr", "img", "input",
        "keygen", "link", "meta", "param", "source", "track", "wbr"
    ].map { Array($0.utf8) })

    /// Never pushed again once the document has them.
    static let documentNames: Set<[UInt8]> = Set(["html", "head", "body"].map { Array($0.utf8) })

    /// Start tags after which SwiftSoup reads raw text in some insertion
    /// modes and markup in others, which a scan of the bytes cannot follow:
    /// inside `select` it ignores `style` and `title`, in a frameset most
    /// start tags. A `noscript` is one only in the head, where SwiftSoup
    /// reads some of its content as text; in the body it is markup
    /// (measured).
    static let alwaysModeDependent: Set<[UInt8]> = Set(["select", "frameset"].map { Array($0.utf8) })
    static let noscript = Array("noscript".utf8)

    /// The start tags SwiftSoup's head takes without leaving it
    /// (`InHead`), from before the document's `html` on.
    static let certainHeadStartTags: Set<[UInt8]> = Set([
        "html", "head", "base", "basefont", "bgsound", "command", "link", "meta", "title", "noframes",
        "style", "noscript", "script"
    ].map { Array($0.utf8) })
    /// The end tags after which the tree builder has left the head, or may
    /// have.
    static let headLeavingEndTags: Set<[UInt8]> = Set(["head", "body", "html", "br"].map { Array($0.utf8) })
    /// The only start tags a `noscript` in the head makes elements of
    /// (`InHeadNoscript`, by way of `InHead`); every other tag in it is
    /// text. Of the empty ones it takes, none pushes, so only these count.
    static let headNoscriptElements: Set<[UInt8]> = Set(["style", "noframes"].map { Array($0.utf8) })

    /// Start tags the head takes; any other one ends the head for good
    /// (`<body>` included). `command` is one of them (SwiftSoup's
    /// `baseEtc`): without it a `<command>` was taken to end the head, and
    /// the head's `noscript` after it, whose tags SwiftSoup reads as text,
    /// was read as markup, so a `<plaintext>` there stopped the scan before
    /// a thousand divs.
    static let headStartTags: Set<[UInt8]> = Set([
        "html", "head", "base", "basefont", "bgsound", "command", "link", "meta", "title", "noscript",
        "noframes", "style", "script", "template"
    ].map { Array($0.utf8) })

    static let table = Array("table".utf8)
    static let td = Array("td".utf8)
    static let th = Array("th".utf8)
    static let tr = Array("tr".utf8)
    static let p = Array("p".utf8)
    static let li = Array("li".utf8)
    static let dd = Array("dd".utf8)
    static let dt = Array("dt".utf8)
    static let option = Array("option".utf8)
    static let optgroup = Array("optgroup".utf8)
    static let form = Array("form".utf8)
    static let tableSections: Set<[UInt8]> = Set(["tbody", "thead", "tfoot"].map { Array($0.utf8) })

    private static func names(_ list: [String]) -> Set<[UInt8]> {
        Set(list.map { Array($0.utf8) })
    }

    /// The active formatting elements' names.
    static let formattingNames = names([
        "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u"
    ])

    /// Elements that put a marker in the active formatting list, which
    /// their closing clears back to.
    static let markers = names(["td", "th", "caption", "applet", "marquee", "object", "template"])
    /// Markers SwiftSoup may pop without clearing the active formatting
    /// list back to them (a `</table>` over an `object`), which leaves their
    /// marker in the list: a cell closed later then clears only back to it.
    static let markersLeftInTheList = names(["applet", "marquee", "object", "template"])
    /// Start tags SwiftSoup 2.13.5's body inserts without first rebuilding
    /// the active formatting elements: `InBodyStartPClosers`, the headings,
    /// `pre`, `listing`, `li`, `dd`, `dt`, `table` and `form`. Every other
    /// start tag, and every run of text, may rebuild them.
    static let insertsWithoutRebuilding = names([
        "address", "article", "aside", "blockquote", "center", "details", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "header", "hgroup", "menu", "nav", "ol", "p", "section", "summary",
        "ul", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "listing", "li", "dd", "dt", "table", "form"
    ])

    /// Where the adoption agency stops looking for a formatting element
    /// held below: one of SwiftSoup 2.13.5's markers ends the active
    /// formatting list's search (`getActiveFormattingElement`), and a
    /// `table` the agency's scope (`TagSets.inScope`). Not HTML's: SwiftSoup
    /// pushes no marker for a `template`, which is neither.
    static let agencyMarkers = names(["td", "th", "caption", "applet", "marquee", "object"])
    static let agencyBoundaries = agencyMarkers.union(names(["table"]))
    static let cells = names(["td", "th"])

    static let tableStructure = names([
        "table", "tbody", "thead", "tfoot", "tr", "td", "th", "caption", "colgroup", "col"
    ])

    /// SwiftSoup 2.13.5's special elements (`TagSets.special`), the only ones
    /// the adoption agency takes as its furthest block.
    static let specialNames = names([
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body",
        "br", "button", "caption", "center", "col", "colgroup", "command", "dd", "details", "dir", "div", "dl",
        "dt", "embed", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2",
        "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "isindex",
        "li", "link", "listing", "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object",
        "ol", "p", "param", "plaintext", "pre", "script", "section", "select", "style", "summary", "table",
        "tbody", "td", "textarea", "tfoot", "th", "thead", "title", "tr", "ul", "wbr", "xmp"
    ])

    /// Table parts whose content SwiftSoup may foster parent, so the text
    /// and elements read while one is innermost may go to an element below
    /// the table (`colgroup` hands "anything else" back to the table).
    static let fosteringTableParts = names(["table", "tbody", "thead", "tfoot", "tr", "colgroup"])

    /// Start tags the body may drop or insert without leaving them open,
    /// which this scan otherwise holds as open: a `form` while SwiftSoup's
    /// form pointer is set or in a table, a `frame`, an `rp` or `rt` with
    /// no `ruby` in scope (`InBodyStartRuby`), and an `isindex`.
    static let mayNotStayOpen = names(["form", "frame", "isindex", "rp", "rt"])

    /// The elements SwiftSoup may close for the tag that closed one named
    /// `name`: the scan closes the innermost, and where that one may already
    /// be closed the tree builder may close a lower one of these instead.
    static func closingKind(of name: [UInt8]) -> Set<[UInt8]> {
        if headings.contains(name) {
            return headings
        }
        if name == dd || name == dt {
            return definitionTargets
        }
        if name == td || name == th || name == tr || tableSections.contains(name) {
            return sectionEndTargets
        }
        if name == option || name == optgroup {
            return optionKinds
        }
        return endTagTargets(name).union([name])
    }

    private static let optionKinds = names(["option", "optgroup"])

    /// What "generate implied end tags" closes.
    static let impliedEndTagNames = names(["dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc"])

    /// HTML's default scope boundaries, with `select` and the foreign
    /// integration points as well.
    private static let defaultScopeBoundaries = names([
        "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template", "select",
        "svg", "math", "mi", "mo", "mn", "ms", "mtext", "annotation-xml", "foreignobject", "desc", "title"
    ])

    /// End tags whose handler, once the element is in scope, generates
    /// implied end tags and pops everything above it.
    private static let blockClosers = names([
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu",
        "nav", "ol", "pre", "section", "summary", "ul", "dd", "dt"
    ])

    /// For an end tag that pops everything above its element once that is
    /// in scope, the names that end the scope: crossing one, the tree
    /// builder would ignore the end tag. Nil for any other end tag.
    static func scopeBoundaries(crossedByEndTagOf name: [UInt8]) -> Set<[UInt8]>? {
        if name == td || name == th || tableSections.contains(name) || name == tr || name == caption {
            return tableScopeBoundaries
        }
        if name == table {
            return tableEndScopeBoundaries
        }
        if name == p {
            return buttonScopeBoundaries
        }
        if name == li {
            return listItemScopeBoundaries
        }
        if headings.contains(name) {
            return headingScopeBoundaries
        }
        if blockClosers.contains(name) {
            return defaultScopeBoundaries
        }
        return nil
    }

    /// The names whose nearest held element the tree builder may close for
    /// the end tag `name`, with everything above it. A table part's end tag
    /// also closes the parts it contains, which the scan may hold without
    /// the part (a `td`'s weight stands for its implied `tr` and `tbody`).
    static func endTagTargets(_ name: [UInt8]) -> Set<[UInt8]> {
        if headings.contains(name) {
            return headings
        }
        if name == tr {
            return rowEndTargets
        }
        if tableSections.contains(name) {
            return sectionEndTargets
        }
        if name == table {
            return tableEndTargets
        }
        return [name]
    }

    /// A `</table>` closes the cell, caption or column group it is read in
    /// (`closeCell`, `processEndTag(caption)`), even with no `table` held, as
    /// in a table part's fragment, where a `caption` closed this way took
    /// an `object` held inside it with it.
    private static let tableEndTargets = names(["table", "caption", "colgroup", "tbody", "thead", "tfoot", "tr", "td", "th"])

    /// How the tree builder may close held elements for a start tag:
    /// `targets` found looking down from the current node, a search that
    /// stops at the first of `stopsAt` (each one an element the builder's own
    /// search stops at); or, with `clearsAboveStop`, everything above the
    /// nearest of `stopsAt`.
    struct ClosingRule {
        let targets: Set<[UInt8]>
        let stopsAt: Set<[UInt8]>
        var clearsAboveStop = false
        /// The builder looks only at the current node.
        var currentNodeOnly = false
    }

    private static let listItemStops = names(["ul", "ol", "dl", "table", "td", "th", "caption", "button"])
    private static let buttonScopeBoundaries = defaultScopeBoundaries.union(names(["button"]))
    private static let listItemScopeBoundaries = defaultScopeBoundaries.union(names(["ol", "ul"]))
    private static let headingScopeBoundaries = defaultScopeBoundaries.union(headings)
    private static let tableScopeBoundaries = names(["table", "template", "html", "select"])
    private static let tableEndScopeBoundaries = names(["template", "html", "select"])
    private static let rowEndTargets = names(["tr", "td", "th"])
    private static let sectionEndTargets = names(["tbody", "thead", "tfoot", "tr", "td", "th"])
    private static let definitionTargets = names(["dd", "dt"])
    private static let caption = Array("caption".utf8)
    private static let menuitem = Array("menuitem".utf8)
    private static let button = Array("button".utf8)
    static let anchor = Array("a".utf8)
    private static let nobr = Array("nobr".utf8)

    static func closingRules(forStartTag name: [UInt8]) -> [ClosingRule] {
        var rules: [ClosingRule] = []
        if closesParagraph.contains(name) || mayCloseParagraph.contains(name) {
            rules.append(ClosingRule(targets: [p], stopsAt: buttonScopeBoundaries))
        }
        if name == li {
            rules.append(ClosingRule(targets: [li], stopsAt: listItemStops))
        }
        if name == dd || name == dt {
            rules.append(ClosingRule(targets: definitionTargets, stopsAt: listItemStops))
        }
        if headings.contains(name) {
            rules.append(ClosingRule(targets: headings, stopsAt: [], currentNodeOnly: true))
        }
        if name == option || name == optgroup {
            rules.append(ClosingRule(targets: [option], stopsAt: [], currentNodeOnly: true))
        }
        if name == menuitem {
            rules.append(ClosingRule(targets: [name], stopsAt: [], currentNodeOnly: true))
        }
        if name == button {
            rules.append(ClosingRule(targets: [name], stopsAt: defaultScopeBoundaries))
        }
        if name == anchor || name == nobr {
            rules.append(ClosingRule(targets: [name], stopsAt: markers))
        }
        if impliedEndTagStarts.contains(name) {
            rules.append(ClosingRule(targets: impliedEndTagNames, stopsAt: []))
        }
        if name == template {
            rules.append(ClosingRule(targets: [], stopsAt: [], clearsAboveStop: true))
        }
        return rules
    }

    private static let template = Array("template".utf8)
    /// Start tags that close a `p` in some modes or builds (`table` not in
    /// quirks mode): never popped for, but a `p` held may be closed.
    private static let mayCloseParagraph = names(["table", "hr", "isindex", "image", "input", "keygen"])
    /// Start tags that generate implied end tags.
    private static let impliedEndTagStarts = names(["rb", "rtc", "rp", "rt"])
    static let headings: Set<[UInt8]> = Set(["h1", "h2", "h3", "h4", "h5", "h6"].map { Array($0.utf8) })

    /// Start tags that close a `p` in button scope: SwiftSoup 2.13.5's
    /// `InBodyStartPClosers` plus the others whose handlers close one. Not
    /// HTML's list: SwiftSoup inserts `dialog`, `main`, `xmp` and
    /// `plaintext` as any other element, and a `p` closed for one here
    /// stayed open there.
    static let closesParagraph: Set<[UInt8]> = Set([
        "address", "article", "aside", "blockquote", "center", "details", "dir", "div",
        "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "menu",
        "nav", "ol", "p", "section", "summary", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
        "listing", "form", "li", "dd", "dt"
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

// MARK: - Attributes

/// SwiftSoup 2.13.5's states inside a tag after its name, as one step, so
/// the second scan and `FormattingAttributeBound` read tags alike.
private enum TagAttributeReading {
    enum State: Equatable {
        case beforeName
        case name
        case afterName
        case beforeValue
        case quotedValue(UInt8)
        case unquotedValue
        case afterQuotedValue
        case selfClosing
    }

    enum Step {
        /// The byte is read; `startsAttribute` when it begins an attribute's name.
        case consume(State, startsAttribute: Bool)
        /// The byte is read again in the new state.
        case reconsume(State)
        /// The byte is the tag's `>`; `selfClosing` for `/>`.
        case end(selfClosing: Bool)
    }

    static func step(_ state: State, _ byte: UInt8) -> Step {
        let isWhitespace = ScannedTagName.isTokenizerWhitespace(byte)
        switch state {
        case .beforeName:
            if isWhitespace { return .consume(.beforeName, startsAttribute: false) }
            if byte == 0x2F { return .consume(.selfClosing, startsAttribute: false) }
            if byte == 0x3E { return .end(selfClosing: false) }
            // Quotes, "<", "=" and NUL start a name here as any other byte does.
            return .consume(.name, startsAttribute: true)
        case .name:
            if isWhitespace { return .consume(.afterName, startsAttribute: false) }
            if byte == 0x2F { return .consume(.selfClosing, startsAttribute: false) }
            if byte == 0x3D { return .consume(.beforeValue, startsAttribute: false) }
            if byte == 0x3E { return .end(selfClosing: false) }
            return .consume(.name, startsAttribute: false)
        case .afterName:
            if isWhitespace { return .consume(.afterName, startsAttribute: false) }
            if byte == 0x2F { return .consume(.selfClosing, startsAttribute: false) }
            if byte == 0x3D { return .consume(.beforeValue, startsAttribute: false) }
            if byte == 0x3E { return .end(selfClosing: false) }
            return .consume(.name, startsAttribute: true)
        case .beforeValue:
            if isWhitespace { return .consume(.beforeValue, startsAttribute: false) }
            if byte == 0x22 || byte == 0x27 { return .consume(.quotedValue(byte), startsAttribute: false) }
            if byte == 0x3E { return .end(selfClosing: false) }
            return .consume(.unquotedValue, startsAttribute: false)
        case let .quotedValue(quote):
            return .consume(byte == quote ? .afterQuotedValue : state, startsAttribute: false)
        case .unquotedValue:
            if isWhitespace { return .consume(.beforeName, startsAttribute: false) }
            if byte == 0x3E { return .end(selfClosing: false) }
            return .consume(.unquotedValue, startsAttribute: false)
        case .afterQuotedValue:
            if isWhitespace { return .consume(.beforeName, startsAttribute: false) }
            if byte == 0x2F { return .consume(.selfClosing, startsAttribute: false) }
            if byte == 0x3E { return .end(selfClosing: false) }
            // Reconsumed as the start of the next attribute.
            return .reconsume(.beforeName)
        case .selfClosing:
            if byte == 0x3E { return .end(selfClosing: true) }
            // Reconsumed before an attribute name.
            return .reconsume(.beforeName)
        }
    }
}

/// The most attribute names any formatting start tag could hold, for a body
/// whose tokenizer states the second scan cannot follow: each formatting
/// name is read as a tag from its first letter, as if the tokenizer were in
/// its data state there. Every read is run at once, one reading per state,
/// since reads in the same state at the same byte go on alike; so the cost
/// is linear however the reads overlap (`<b/a=y<b/a=y…` has every read run
/// to the end).
private enum FormattingAttributeBound {
    /// Positions in `counts`: the tag name, then each attribute state.
    private static let stateCount = 10
    private static let tagNameSlot = 0

    private static func slot(of state: TagAttributeReading.State) -> Int {
        switch state {
        case .beforeName: return 1
        case .name: return 2
        case .afterName: return 3
        case .beforeValue: return 4
        case let .quotedValue(quote): return quote == 0x22 ? 5 : 6
        case .unquotedValue: return 7
        case .afterQuotedValue: return 8
        case .selfClosing: return 9
        }
    }

    private static let states: [TagAttributeReading.State?] = [
        nil, .beforeName, .name, .afterName, .beforeValue,
        .quotedValue(0x22), .quotedValue(0x27), .unquotedValue, .afterQuotedValue, .selfClosing
    ]

    static func maximumAttributeCount(in bytes: UnsafeBufferPointer<UInt8>, nameStarts: [Int]) -> Int {
        var maximum = 0
        // The most attributes begun so far by a read in each state, or -1.
        var counts = [Int](repeating: -1, count: stateCount)
        var next = [Int](repeating: -1, count: stateCount)
        var startCursor = 0
        var active = false
        var index = 0
        while index < bytes.count {
            if startCursor < nameStarts.count, nameStarts[startCursor] == index {
                counts[tagNameSlot] = max(counts[tagNameSlot], 0)
                startCursor += 1
                active = true
            }
            guard active else {
                // Nothing is being read: go to the next name.
                guard startCursor < nameStarts.count else { break }
                index = nameStarts[startCursor]
                continue
            }
            let byte = bytes[index]
            for position in 0..<stateCount {
                next[position] = -1
            }
            active = false
            for position in 0..<stateCount where counts[position] >= 0 {
                var attributes = counts[position]
                var state = states[position]
                // A name ends at whitespace, "/" or ">", which the attribute
                // states then read; NUL and "<" go on in it.
                if state == nil {
                    if ScannedTagName.endsTagName(byte) {
                        state = .beforeName
                    } else {
                        next[tagNameSlot] = max(next[tagNameSlot], attributes)
                        active = true
                        continue
                    }
                }
                while let current = state {
                    switch TagAttributeReading.step(current, byte) {
                    case let .consume(following, startsAttribute):
                        if startsAttribute {
                            attributes += 1
                        }
                        let target = slot(of: following)
                        next[target] = max(next[target], attributes)
                        active = true
                        state = nil
                    case let .reconsume(following):
                        state = following
                    case .end:
                        maximum = max(maximum, attributes)
                        state = nil
                    }
                }
            }
            swap(&counts, &next)
            index += 1
        }
        // A tag the input ended inside is never emitted; counted anyway.
        for attributes in counts {
            maximum = max(maximum, attributes)
        }
        return maximum
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
    /// Every `<`. SwiftSoup reads no token but text without one, so this is
    /// the most tags, comments and declarations it can read, and one fewer
    /// than the most runs of text they can split (`x<?>` splits one; a run
    /// of text costs the tree builder what a start tag does).
    private(set) var tokenCount = 0
    /// Every `<` followed by a formatting element's name.
    private(set) var formattingTagCount = 0
    /// Where each of those names starts.
    private(set) var formattingNameStarts: [Int] = []
    /// Over every `<`, the formatting tags before it.
    private(set) var formattingTagsAcrossTokens = 0
    /// Whether any `</` and a formatting element's name, or `<a`, occurs:
    /// the tags that can run the adoption agency.
    private(set) var mayRunAdoptionAgency = false

    init(bytes: UnsafeBufferPointer<UInt8>) {
        let count = bytes.count
        var index = 0
        while index < count {
            guard bytes[index] == 0x3C else {
                index += 1
                continue
            }
            tokenCount += 1
            formattingTagsAcrossTokens = Saturating.add(formattingTagsAcrossTokens, formattingTagCount)
            if !mayRunAdoptionAgency,
               index + 2 < count,
               bytes[index + 1] == 0x2F,
               ScannedTagName.formattingNames.contains(Self.name(in: bytes, from: index + 2)) {
                mayRunAdoptionAgency = true
            }
            let nameStart = index + 1
            guard nameStart < count, ScannedTagName.isASCIIAlpha(bytes[nameStart]) else {
                index += 1
                continue
            }
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
            if ScannedTagName.formattingNames.contains(name) {
                formattingTagCount += 1
                formattingNameStarts.append(nameStart)
                if name == ScannedTagName.anchor {
                    mayRunAdoptionAgency = true
                }
            }
            index = nameStart
        }
    }

    /// The lowercased name starting at `start`, at most `nameLengthRead`
    /// bytes of it (longer than any formatting element's name).
    private static func name(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> [UInt8] {
        var name: [UInt8] = []
        var index = start
        while index < bytes.count, index - start < nameLengthRead, !ScannedTagName.endsTagName(bytes[index]) {
            name.append(ScannedTagName.lowercasedASCII(bytes[index]))
            index += 1
        }
        return name
    }
}

// MARK: - Second scan

/// Tokenizes as SwiftSoup 2.13.5 does and keeps a stack of the elements
/// that may still be open.
private struct TokenizingScanner {
    private struct OpenElement {
        let name: [UInt8]
        let weight: Int
        /// The `pushCount` after its push.
        let pushedAt: Int
        /// For a formatting element, its `formattingKeys` entry; otherwise -1.
        let formattingKey: Int
        /// Where the nearest marker below it sat when it was pushed, if the
        /// tree builder certainly held that marker then (so its entry in the
        /// active formatting list follows the marker's, and goes when the
        /// marker closes); otherwise -1.
        let clearedWithMarkerAt: Int
        /// A formatting element the adoption agency has certainly taken out
        /// of the active formatting list (`retireFromTheList`), though this
        /// scan still holds it.
        var retiredFromTheList = false
    }

    private struct Tag {
        let name: [UInt8]
        let isEndTag: Bool
        let selfClosing: Bool
        /// Index after the tag's `>`, or nil when the input ended inside it.
        let end: Int?
        /// Attribute names begun, duplicates included.
        let attributeCount: Int
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private let count: Int
    private let limit: Int
    private var stack: [OpenElement] = []
    private var openWeight = 0
    private var deepestOpenWeight = 0
    /// Counts pushes; an element records it when pushed (`OpenElement.pushedAt`).
    private var pushCount = 0
    /// Events after which the tree builder may have closed the elements this
    /// stack holds from `index` up: `pushCount` then, and that index. Kept
    /// with both rising, as a later event from a lower index covers an
    /// earlier one from a higher (`markPossiblyClosed(from:)`).
    private var possiblyClosedMarks: [(index: Int, pushCount: Int)] = []
    /// Where each name sits in `stack`, lowest first, so no lookup walks
    /// the stack: the scan must stay linear in what a sender writes.
    private var positionsByName: [[UInt8]: [Int]] = [:]
    /// Formatting elements held, open or kept after an end tag crossed them
    /// (`ghost`), by name: the active formatting list can hold no more.
    private var formattingHeldByName: [[UInt8]: Int] = [:]
    private var formattingHeld = 0
    /// The formatting elements on `stack` that are certainly open, lowest
    /// first, with their keys: every other held one may be off the tree
    /// builder's stack, where SwiftSoup rebuilds it
    /// (`reconstructFormattingElements`). Elements leave it from the top
    /// only, since a possibly-closed mark covers everything above its index.
    private var certainlyOpenFormatting: [(index: Int, key: Int)] = []
    /// Formatting start tags by their bytes, `<` to `>`: the same bytes are
    /// the same name and attributes, which is what SwiftSoup's active
    /// formatting list compares (tags it would take as the same but written
    /// differently get keys of their own, which only over-counts).
    private var formattingKeys: [[UInt8]: Int] = [:]
    /// By key: held, held and certainly open, and the rebuild cost.
    private var heldByKey: [Int] = []
    private var certainlyOpenByKey: [Int] = []
    private var rebuildCostByKey: [Int] = []
    /// Over the keys, the held elements that may be off the stack, at most
    /// three of each: the active formatting list keeps no more than three
    /// entries of one name and attributes after its last marker (Noah's
    /// ark), and a rebuild stops at the marker. And those elements' rebuild
    /// costs. `<div><b>x</div>` 800 times keeps three `b`s, not 800.
    private var rebuildCandidates = 0
    private var rebuildCandidatesCost = 0
    /// Over every token, the held formatting elements that may be off the
    /// tree builder's stack: each costs a search of the stack when SwiftSoup
    /// looks for the last one on it.
    private(set) var rebuildCandidatesAcrossTokens = 0
    /// Over every token, the rebuild costs of those elements.
    private(set) var rebuildCostAcrossTokens = 0
    /// `EmailDOMParseAdmission.ParseCost.formattingCompareWork`.
    private(set) var formattingCompareWork = 0
    /// Whether a start tag only the body takes has been read, so the tree
    /// builder has left the head.
    private var hasLeftHead = false
    /// Whether a start tag after which SwiftSoup's reading depends on its
    /// insertion mode has been read (`ScannedTagName.alwaysModeDependent`, or
    /// a `noscript` in the head). Up to that tag this scan reads the bytes
    /// as SwiftSoup does; after it, nothing it says can be trusted.
    private(set) var readModeDependentTag = false
    /// Whether the tree builder is certainly still in the head: a document
    /// with nothing yet but whitespace, comments, declarations and the tags
    /// the head takes (`ScannedTagName.certainHeadStartTags`). A `noscript`
    /// read then is one in the head, which this scan follows
    /// (`inHeadNoscript`); one read before the head has certainly ended
    /// otherwise is mode-dependent.
    private var certainlyInHead: Bool
    /// Inside a `noscript` the head took: SwiftSoup reads every tag there as
    /// text but `style` and `noframes` (raw text, as anywhere) and the
    /// `</noscript>` that ends it.
    private var inHeadNoscript = false

    // Child moves (`ParseCost.childMoveWork`).
    //
    // Every node the tree builder inserts goes to its current node, which is
    // the element this scan holds innermost or one below it the scan still
    // holds though the builder closed it (or an element the scan does not
    // hold, never a furthest block). So each node is counted on the
    // innermost element, and `childPrefix[k]` is the count over
    // `stack[0...k]`: what may have been given to an element is the count
    // from it up. When an element is popped, its count goes to the element
    // below it, unless the builder certainly held it from its push to its
    // pop (`isRobustlyOpen`), so everything counted on it went to it or to
    // elements above it. A table part the builder held all along passes on
    // only what it may have foster parented below the table
    // (`fosterableCounts`). `childPrefix` is a running sum, so every step is
    // constant work.
    //
    // `possiblyClosedMarks` is not enough for that: the depth bound only
    // needs this scan never to close what the tree builder keeps, and it
    // closes a held element the builder may already have closed, where the
    // builder may close a lower one instead (`<div><div/></div>`). So
    // `robustMarks` holds every mark and, where this scan closes an element
    // that may already be closed, a mark from the lowest element the builder
    // may close in its place (`doubtClosing(of:)`).
    private var childPrefix: [Int] = []
    /// By position in `stack`, for a table part that fosters
    /// (`ScannedTagName.fosteringTableParts`): the nodes counted on it that
    /// the builder may have foster parented (text other than whitespace,
    /// tags other than table parts), and what it was passed from above.
    private var fosterableCounts: [Int] = []
    /// Bytes of text read since the last markup, and whether any of them
    /// is not whitespace (SwiftSoup fosters only such a run in a table).
    private var readTextSinceMarkup = false
    private var readNonWhitespaceSinceMarkup = false
    private var robustMarks: [(index: Int, pushCount: Int)] = []
    /// Where the special elements held sit in `stack`, lowest first.
    private var specialPositions: [Int] = []
    /// Where the markers held sit in `stack`, lowest first.
    private var markerPositions: [Int] = []
    /// Where the `ScannedTagName.agencyBoundaries` held sit, lowest first.
    private var agencyBoundaryPositions: [Int] = []
    /// By formatting name, how many of the lowest held elements of that
    /// name are retired from the active formatting list (`OpenElement
    /// .retiredFromTheList`): a retired one is always below every one held
    /// after it.
    private var retiredByName: [[UInt8]: Int] = [:]
    /// By formatting name, the `pushCount` when the first and the latest
    /// element of it popped but kept in the active formatting list was
    /// kept: a copy of one is rebuilt at or above the top of the stack of
    /// that moment, never below it.
    private var firstKeptAtByName: [[UInt8]: Int] = [:]
    private var latestKeptAtByName: [[UInt8]: Int] = [:]
    /// By formatting name, the `pushCount` at the first token after the
    /// first keep that may rebuild formatting elements: before it no copy of
    /// a kept one is on the builder's stack, and the agency finding a kept
    /// one there only takes it out of the list, moving nothing.
    private var firstPossibleCopyAtByName: [[UInt8]: Int] = [:]
    /// Names kept since the last token that may rebuild.
    private var keptAwaitingRebuild: Set<[UInt8]> = []
    /// By formatting name, the kept ones the agency has certainly taken out
    /// of the list (`consumeAKeptOne`).
    private var keptConsumedByName: [[UInt8]: Int] = [:]
    /// Over the formatting keys, the held elements of each, at most three
    /// (Noah's ark): the most the tree builder can rebuild at one token,
    /// whatever this scan knows about which are open.
    private var rebuildableHeld = 0
    /// The `pushCount` after the latest push of a marker SwiftSoup may have
    /// left in its active formatting list: one of
    /// `ScannedTagName.markersLeftInTheList`, or any marker pushed before a
    /// `</td>` or `</th>` whose cell may not be in table scope, which
    /// SwiftSoup answers by leaving the open cell for the row's mode, where
    /// the cell is later popped without the clear.
    private var latestMarkerPossiblyLeftInTheList = 0
    /// `EmailDOMParseAdmission.ParseCost.childMoveWork`.
    private(set) var childMoveWork = 0

    private let isTableContextFragment: Bool

    init(bytes: UnsafeBufferPointer<UInt8>, limit: Int, isTableContextFragment: Bool, readsHead: Bool) {
        self.bytes = bytes
        self.count = bytes.count
        self.limit = limit
        self.isTableContextFragment = isTableContextFragment
        self.certainlyInHead = readsHead
    }

    private var bound: Int {
        deepestOpenWeight + EmailDOMParseAdmission.enclosingNodeCount + EmailDOMParseAdmission.leafAllowance
    }

    mutating func run() -> Int {
        var index = 0
        while index < count {
            let byte = bytes[index]
            guard byte == 0x3C else {
                // Text other than whitespace ends the head; in a `noscript`
                // there it is the `noscript`'s.
                let isWhitespace = ScannedTagName.isTokenizerWhitespace(byte)
                if certainlyInHead, !inHeadNoscript, !isWhitespace {
                    certainlyInHead = false
                }
                readTextSinceMarkup = true
                if !isWhitespace {
                    readNonWhitespaceSinceMarkup = true
                }
                index += 1
                continue
            }
            // The run of text before this markup is one node (the tokenizer
            // emits a run as one token, and the tree builder appends it).
            if readTextSinceMarkup {
                noteTokenThatMayRebuild()
                countChildren(1, fosterable: readNonWhitespaceSinceMarkup, rebuildsFormatting: true)
                readTextSinceMarkup = false
                readNonWhitespaceSinceMarkup = false
            }
            guard let next = markup(at: index) else {
                break
            }
            chargeRebuilds()
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

        if inHeadNoscript,
           ScannedTagName.isASCIIAlpha(byte)
            || (byte == 0x2F && next + 1 < count && ScannedTagName.isASCIIAlpha(bytes[next + 1])) {
            return headNoscriptTag(at: index)
        }

        if ScannedTagName.isASCIIAlpha(byte) {
            let tag = readTag(nameStart: next, isEndTag: false)
            guard let end = tag.end else { return nil }
            // A self-closing `html` or `head` is inserted empty, which
            // leaves the head (measured), so only void tags may close.
            if certainlyInHead,
               !ScannedTagName.certainHeadStartTags.contains(tag.name)
                || (tag.selfClosing && !ScannedTagName.voidNames.contains(tag.name)) {
                certainlyInHead = false
            }
            openElement(
                named: tag.name,
                tagStart: index,
                tagLength: end - index,
                attributeCount: tag.attributeCount,
                selfClosing: tag.selfClosing
            )
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
                if ScannedTagName.headLeavingEndTags.contains(tag.name) {
                    certainlyInHead = false
                }
                closeElement(named: tag.name)
                return end
            }
            if first == 0x3E {
                return nameStart + 1
            }
            // Comments and declarations are a node each, which a table
            // keeps (CDATA is text, fostered: counted as one anyway).
            countChildren(1)
            return endOfBogusComment(from: nameStart)
        case 0x21: // "<!"
            countChildren(1)
            return endOfMarkupDeclaration(from: next + 1)
        case 0x3F: // "<?"
            countChildren(1)
            return endOfBogusComment(from: next)
        default:
            // A "<" read as text.
            if !inHeadNoscript {
                certainlyInHead = false
            }
            readTextSinceMarkup = true
            readNonWhitespaceSinceMarkup = true
            return next
        }
    }

    /// A start or end tag inside a `noscript` the head took; comments,
    /// declarations and text there are read as anywhere. The `noscript`
    /// ends where its `</noscript>` is read; every other end tag there is
    /// ignored, and every start tag but `style` and `noframes` is text.
    private mutating func headNoscriptTag(at index: Int) -> Int? {
        let next = index + 1
        if ScannedTagName.isASCIIAlpha(bytes[next]) {
            let tag = readTag(nameStart: next, isEndTag: false)
            guard let end = tag.end else { return nil }
            guard ScannedTagName.headNoscriptElements.contains(tag.name) else { return end }
            openElement(
                named: tag.name,
                tagStart: index,
                tagLength: end - index,
                attributeCount: tag.attributeCount,
                selfClosing: tag.selfClosing
            )
            switch ScannedTagName.rawText(after: tag.name, selfClosing: tag.selfClosing) {
            case .rcdataOrRawtext:
                return endOfRawText(named: tag.name, from: end)
            case .none, .scriptData, .plaintext:
                return end
            }
        }
        let tag = readTag(nameStart: next + 1, isEndTag: true)
        guard let end = tag.end else { return nil }
        if tag.name == ScannedTagName.noscript {
            inHeadNoscript = false
            closeElement(named: tag.name)
        }
        return end
    }

    // MARK: Tree

    /// Before a start tag is pushed: its implied closes, and its cost to the
    /// active formatting list. Void and document tags push nothing but may
    /// still close (`<hr>` may close a `p`).
    private mutating func openElement(
        named name: [UInt8],
        tagStart: Int,
        tagLength: Int,
        attributeCount: Int,
        selfClosing: Bool
    ) {
        var entersHeadNoscript = false
        if ScannedTagName.alwaysModeDependent.contains(name) {
            readModeDependentTag = true
        } else if name == ScannedTagName.noscript, !hasLeftHead {
            // A self-closing one leaves SwiftSoup's head in a state of its own.
            if certainlyInHead, !selfClosing {
                entersHeadNoscript = true
            } else {
                readModeDependentTag = true
            }
        }
        defer {
            if entersHeadNoscript {
                inHeadNoscript = true
            }
        }
        if !ScannedTagName.headStartTags.contains(name) {
            hasLeftHead = true
        }
        // An `<a>` while one is in the active formatting list first runs the
        // adoption agency for it (SwiftSoup 2.13.5 inserts a `<nobr>` as any
        // other element).
        if name == ScannedTagName.anchor {
            chargeAdoptionAgency(for: name, atStartTag: true)
        }
        closeImpliedElements(before: name)
        if !ScannedTagName.insertsWithoutRebuilding.contains(name) {
            noteTokenThatMayRebuild()
        }
        // The element (or the empty one) goes to the current node once the
        // implied closes are done; in a table, all but a table part may be
        // foster parented (a `table` closes the one it is in, and goes
        // below it).
        let fosterable = name == ScannedTagName.table || !ScannedTagName.tableStructure.contains(name)
        countChildren(1, fosterable: fosterable, rebuildsFormatting: fosterable)
        if ScannedTagName.formattingNames.contains(name) {
            let sameName = formattingHeldByName[name, default: 0]
            formattingCompareWork = Saturating.add(
                formattingCompareWork,
                Saturating.add(Saturating.multiply(formattingHeld, 16), Saturating.multiply(sameName, tagLength))
            )
        }
        let weight = ScannedTagName.weight(of: name)
        guard weight > 0 else { return }
        // Outside a table SwiftSoup ignores a table part's start tag, and in
        // a table part's fragment context it ignores a table's too (and the
        // parts its mode does not take). Held but perhaps never inserted,
        // such an element is not certainly open from the start.
        // SwiftSoup closes a self-closing element at once (`<table/>`): it
        // stays counted, but is not open.
        let mayBeIgnored = selfClosing || (ScannedTagName.tableStructure.contains(name)
            && (isTableContextFragment || (name != ScannedTagName.table && certainlyOpenTable() == nil)))
        let isFormatting = ScannedTagName.formattingNames.contains(name)
        let key = isFormatting
            ? formattingKey(of: tagStart..<(tagStart + tagLength), attributeCount: attributeCount)
            : -1
        var clearedWithMarkerAt = -1
        if isFormatting, let marker = markerPositions.last, isRobustlyOpen(at: marker) {
            clearedWithMarkerAt = marker
        }
        pushCount += 1
        positionsByName[name, default: []].append(stack.count)
        stack.append(OpenElement(
            name: name,
            weight: weight,
            pushedAt: pushCount,
            formattingKey: key,
            clearedWithMarkerAt: clearedWithMarkerAt
        ))
        childPrefix.append(childPrefix.last ?? 0)
        fosterableCounts.append(0)
        if ScannedTagName.specialNames.contains(name) {
            specialPositions.append(stack.count - 1)
        }
        if ScannedTagName.markers.contains(name) {
            markerPositions.append(stack.count - 1)
        }
        if ScannedTagName.agencyBoundaries.contains(name) {
            agencyBoundaryPositions.append(stack.count - 1)
        }
        if ScannedTagName.markersLeftInTheList.contains(name) {
            latestMarkerPossiblyLeftInTheList = pushCount
        }
        if ScannedTagName.mayNotStayOpen.contains(name) {
            markDoubtful(from: stack.count - 1)
        }
        if isFormatting {
            formattingHeldByName[name, default: 0] += 1
            formattingHeld += 1
            updateRebuildCandidates(key: key) {
                $0.heldByKey[key] += 1
                $0.certainlyOpenByKey[key] += 1
            }
            certainlyOpenFormatting.append((index: stack.count - 1, key: key))
        }
        if mayBeIgnored {
            markPossiblyClosed(from: stack.count - 1)
        }
        openWeight += weight
        deepestOpenWeight = max(deepestOpenWeight, openWeight)
    }

    /// An end tag closes the innermost element of its name; or, for the end
    /// tags whose handler pops everything above the element (`</div>` over a
    /// `<p>` left open, `</td>` over a `<font>`), the nearest one with
    /// everything above it, where that is certain to be what the tree
    /// builder does (`crossingClose`). Otherwise nothing is closed here, and
    /// what the tree builder may have closed is marked.
    private mutating func closeElement(named name: [UInt8]) {
        if ScannedTagName.formattingNames.contains(name) {
            // An end tag the agency cannot act on is ignored by the builder
            // (`anyOtherEndTag` stops at the boundary, which is special), so
            // it closes nothing here either: marked as possibly closing
            // everything above the `font` outside a table, a stray
            // `</font>` in one cell left every later cell uncertain.
            if agencyCannotReach(name) {
                return
            }
            chargeAdoptionAgency(for: name, atStartTag: false)
        }
        if ScannedTagName.cells.contains(name), !isCertainlyInTableScope(name) {
            latestMarkerPossiblyLeftInTheList = pushCount
        }
        // `</p>` with no `p` in scope inserts one, `</br>` a `br`; no other
        // end tag inserts anything. SwiftSoup reads `</br>` as `<br>`, which
        // rebuilds the formatting elements first.
        if name == Self.br {
            noteTokenThatMayRebuild()
        }
        if name == ScannedTagName.p || name == Self.br {
            countChildren(1, rebuildsFormatting: name == Self.br)
        }
        if stack.last?.name == name {
            if !isRobustlyOpen(at: stack.count - 1) {
                doubtClosing(of: name)
            }
            popInnermost()
            return
        }
        if crossingClose(named: name) {
            return
        }
        markPossiblyClosed(by: name, lowestTarget: lowestPosition(of: ScannedTagName.endTagTargets(name)))
    }

    /// Pops the nearest `name` and everything above it, when the tree
    /// builder certainly does the same: the element is certainly open (no
    /// event since its push may have closed it out of this scan's sight),
    /// its end tag's handler pops everything above it once it is in scope,
    /// and nothing above it ends that scope. A formatting element popped
    /// this way stays counted (`kept`) unless a marker it was pushed inside
    /// (`td`, `th`, `caption`), while the builder certainly held that
    /// marker, is popped with it, and no marker pushed since that one may
    /// have been left in the active formatting list: the tree builder keeps
    /// it in that list and may rebuild it.
    private mutating func crossingClose(named name: [UInt8]) -> Bool {
        guard let boundaries = ScannedTagName.scopeBoundaries(crossedByEndTagOf: name),
              let index = positionsByName[name]?.last,
              isCertainlyOpen(at: index),
              !boundaries.contains(where: { (positionsByName[$0]?.last ?? -1) > index }) else {
            return false
        }
        if !isRobustlyOpen(at: index) {
            doubtClosing(of: name)
        }
        var keptWeight = 0
        for element in stack[(index + 1)...] {
            if ScannedTagName.formattingNames.contains(element.name) {
                // Only a marker the builder held when this element was
                // pushed takes its entry when it closes: a `caption` it had
                // closed already (`<caption><tbody><font></table>`) is
                // still held here, and the `font` after it stays in the
                // list, rebuilt by the next text. Nor does one pushed before
                // a marker that may have been left in the list, where a
                // clear stops.
                if element.clearedWithMarkerAt >= index,
                   stack[element.clearedWithMarkerAt].pushedAt > latestMarkerPossiblyLeftInTheList {
                    releaseFormatting(element)
                } else {
                    keptWeight += element.weight
                    if firstKeptAtByName[element.name] == nil {
                        firstKeptAtByName[element.name] = pushCount
                        keptAwaitingRebuild.insert(element.name)
                    }
                    latestKeptAtByName[element.name] = pushCount
                }
            }
        }
        while stack.count > index {
            releaseChildren()
            let element = stack.removeLast()
            positionsByName[element.name]?.removeLast()
            openWeight -= element.weight
        }
        dropCertainlyOpenFormatting(from: index)
        openWeight += keptWeight
        return true
    }

    private mutating func releaseFormatting(_ element: OpenElement) {
        formattingHeldByName[element.name, default: 0] -= 1
        formattingHeld -= 1
        let key = element.formattingKey
        updateRebuildCandidates(key: key) { $0.heldByKey[key] -= 1 }
    }

    private mutating func popInnermost() {
        guard !stack.isEmpty else { return }
        releaseChildren()
        let element = stack.removeLast()
        positionsByName[element.name]?.removeLast()
        openWeight -= element.weight
        dropCertainlyOpenFormatting(from: stack.count)
        if ScannedTagName.formattingNames.contains(element.name) {
            releaseFormatting(element)
        }
    }

    /// Pops the innermost element for a start tag that closes it, where the
    /// tree builder may close a lower one of its kind instead if this one
    /// may already be closed.
    private mutating func popInnermostForStartTag() {
        guard let element = stack.last else { return }
        if !isRobustlyOpen(at: stack.count - 1) {
            doubtClosing(of: element.name)
        }
        popInnermost()
    }

    // MARK: Children

    private static let br = Array("br".utf8)

    /// `count` nodes the tree builder may append to its current node;
    /// `fosterable` where, in a table, it may append them below the table
    /// instead. `rebuildsFormatting` for a token the body's rules handle
    /// there, which first rebuilds the formatting elements off the stack:
    /// while fostering, every rebuilt copy goes to the table's parent, side
    /// by side (`insertNode`), not one inside the next, so that parent gains
    /// one for each (`<i><div><p>`, ten `<b>`s, `</p><table>` and 4,000
    /// `x<tr>` gave the `div` 40,000 children).
    private mutating func countChildren(_ count: Int, fosterable: Bool = true, rebuildsFormatting: Bool = false) {
        guard let last = childPrefix.indices.last else { return }
        var count = count
        if fosterable, ScannedTagName.fosteringTableParts.contains(stack[last].name) {
            if rebuildsFormatting {
                count = Saturating.add(count, rebuildableHeld)
            }
            fosterableCounts[last] = Saturating.add(fosterableCounts[last], count)
        }
        childPrefix[last] = Saturating.add(childPrefix[last], count)
    }

    /// Before the innermost element is popped: what was counted on it goes
    /// to the element below, unless the tree builder certainly held it all
    /// along, when only what a table part may have fostered does.
    private mutating func releaseChildren() {
        let index = stack.count - 1
        let total = childPrefix.removeLast()
        let fosterable = fosterableCounts.removeLast()
        let robustlyOpen = isRobustlyOpen(at: index)
        if specialPositions.last == index {
            specialPositions.removeLast()
        }
        if markerPositions.last == index {
            markerPositions.removeLast()
        }
        if agencyBoundaryPositions.last == index {
            agencyBoundaryPositions.removeLast()
        }
        if stack[index].retiredFromTheList {
            retiredByName[stack[index].name, default: 0] -= 1
        }
        guard let below = childPrefix.indices.last else { return }
        let passedOn: Int
        if !robustlyOpen {
            passedOn = total - childPrefix[below]
        } else if ScannedTagName.fosteringTableParts.contains(stack[index].name) {
            passedOn = fosterable
        } else {
            passedOn = 0
        }
        // Passed on whole: what a table part below it may have fostered too.
        countChildren(passedOn)
    }

    /// Before a tag that may run SwiftSoup's adoption agency for the
    /// formatting element `name` (`ParseCost.childMoveWork`).
    ///
    /// The agency finds the last `name` in the active formatting list and
    /// takes the first special element above it as the furthest block. That
    /// is a held one: above the lowest `name` held, or, for one popped but
    /// kept in the list, above the copy the builder may rebuild of it, which
    /// sits at or above the top of the stack of the moment it was kept.
    /// None is moved where the innermost element is a `name` the builder
    /// certainly holds (it, or a rebuilt one above it, is the one found,
    /// with nothing special above), nor where every `name` lies below a
    /// boundary the agency cannot see past (`agencyCannotReach`). The
    /// agency runs once for each `name` in the list, at most eight times,
    /// and each pass appends an adopter to its block and a moved element to
    /// the block's common ancestor, which a later pass may move again.
    private mutating func chargeAdoptionAgency(for name: [UInt8], atStartTag: Bool) {
        let (live, kept) = listEntries(of: name)
        let inTheList = live.count + kept
        guard inTheList > 0 else { return }
        if stack.last?.name == name, isRobustlyOpen(at: stack.count - 1) {
            return
        }
        if agencyCannotReach(name) {
            return
        }
        var floor = live.first ?? stack.count
        if kept > 0, let copyAt = firstPossibleCopyAtByName[name] {
            floor = min(floor, firstPosition(pushedAfter: copyAt))
        }
        let passes = min(Self.adoptionAgencyPasses, inTheList)
        if let block = lowest(of: specialPositions, atOrAbove: floor), let top = childPrefix.last {
            // A later pass may move a block an earlier one appended to.
            let children = Saturating.add(
                top - (block > 0 ? childPrefix[block - 1] : 0),
                Saturating.multiply(passes, 2)
            )
            childMoveWork = Saturating.add(
                childMoveWork,
                Saturating.multiply(passes, Saturating.multiply(children, children))
            )
        }
        countChildren(Saturating.multiply(passes, 2))
        if live.isEmpty {
            consumeAKeptOne(name, atStartTag: atStartTag)
        } else {
            retireIfTheAgencyTakesIt(name, live: live, kept: kept)
        }
    }

    /// The held elements of formatting name `name` still in the active
    /// formatting list as far as this scan knows: those on the stack, lowest
    /// first, and how many were kept after being popped.
    private func listEntries(of name: [UInt8]) -> (live: ArraySlice<Int>, kept: Int) {
        let retired = retiredByName[name, default: 0]
        let onStack = positionsByName[name] ?? []
        let live = onStack[min(retired, onStack.count)...]
        let kept = formattingHeldByName[name, default: 0] - onStack.count - keptConsumedByName[name, default: 0]
        return (live, max(0, kept))
    }

    /// A token after which the builder may have rebuilt formatting elements
    /// (any run of text, and a start tag whose handler rebuilds).
    private mutating func noteTokenThatMayRebuild() {
        guard !keptAwaitingRebuild.isEmpty else { return }
        for name in keptAwaitingRebuild where firstPossibleCopyAtByName[name] == nil {
            firstPossibleCopyAtByName[name] = pushCount
        }
        keptAwaitingRebuild.removeAll()
    }

    /// With no `name` on the stack, the last `name` in the list is a kept
    /// one or its copy, and the agency takes it out of the list: an `<a>`
    /// start tag always (by the agency, or after it as the `a` it finds
    /// still held), an end tag where no copy can be on the stack yet, since
    /// the agency drops one it finds off the stack before looking at scope.
    /// `<p><a href>link</p>` on every line kept an `a` a line and charged
    /// each next `<a>` for the whole document.
    private mutating func consumeAKeptOne(_ name: [UInt8], atStartTag: Bool) {
        let (_, kept) = listEntries(of: name)
        guard kept > 0, atStartTag || firstPossibleCopyAtByName[name] == nil else {
            return
        }
        keptConsumedByName[name, default: 0] += 1
        if kept == 1 {
            firstKeptAtByName[name] = nil
            latestKeptAtByName[name] = nil
            firstPossibleCopyAtByName[name] = nil
            keptAwaitingRebuild.remove(name)
        }
    }

    /// Whether every `name` in the active formatting list lies below a
    /// boundary the builder certainly holds, where the agency finds none
    /// (a marker ends the list's search) or finds one out of scope (a
    /// `table`), and moves nothing: a stray `</font>` in a cell of a table
    /// inside `<font>`. A copy of a kept one rebuilt above a marker can be
    /// found, unless it was kept before the marker was pushed (the rebuild
    /// stops at the marker too); above a `table` it can, as foster parenting
    /// rebuilds it there, and so can a copy of a held one the builder may
    /// have closed.
    private func agencyCannotReach(_ name: [UInt8]) -> Bool {
        let (live, kept) = listEntries(of: name)
        if live.isEmpty, kept == 0 {
            return false
        }
        guard let boundary = agencyBoundaryPositions.last,
              isRobustlyOpen(at: boundary),
              (live.last ?? -1) < boundary else {
            return false
        }
        if ScannedTagName.agencyMarkers.contains(stack[boundary].name) {
            return kept == 0 || (latestKeptAtByName[name] ?? Int.max) < stack[boundary].pushedAt
        }
        return kept == 0 && live.count <= Self.robustCheckLimit && live.allSatisfy { isRobustlyOpen(at: $0) }
    }

    /// How many held elements `agencyCannotReach` checks one by one, so the
    /// scan stays linear.
    private static let robustCheckLimit = 4

    /// Where the agency is certain to take the one `name` in the list out of
    /// it (with no boundary held above it, it is found and in scope, and
    /// every way through the agency removes it; an `<a>` start tag removes
    /// it too when out of scope), and no marker that may have been left in
    /// the list follows it, this scan stops counting it there, though
    /// it still holds it: a stray `</b>` after `<b><div>…</b>`, or the
    /// `<a>`s of every paragraph inside an `<a>` left open, then charges
    /// nothing again.
    private mutating func retireIfTheAgencyTakesIt(_ name: [UInt8], live: ArraySlice<Int>, kept: Int) {
        // A marker left in the list after it would end the search first.
        guard kept == 0, live.count == 1, let only = live.first,
              (agencyBoundaryPositions.last ?? -1) < only,
              latestMarkerPossiblyLeftInTheList < stack[only].pushedAt else {
            return
        }
        stack[only].retiredFromTheList = true
        retiredByName[name, default: 0] += 1
    }

    /// The lowest position in `stack` whose element was pushed after
    /// `pushCount` was `time` (pushes are in stack order).
    private func firstPosition(pushedAfter time: Int) -> Int {
        var low = 0
        var high = stack.count
        while low < high {
            let middle = (low + high) / 2
            if stack[middle].pushedAt <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// SwiftSoup's adoption agency loop runs at most eight times.
    private static let adoptionAgencyPasses = 8

    /// The lowest of the ascending `positions` at or above `floor`.
    private func lowest(of positions: [Int], atOrAbove floor: Int) -> Int? {
        var low = 0
        var high = positions.count
        while low < high {
            let middle = (low + high) / 2
            if positions[middle] < floor {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < positions.count ? positions[low] : nil
    }

    /// Where this scan closes an element the tree builder may already have
    /// closed, the builder may close the lowest one of its kind held, and
    /// everything above it, instead (a formatting element kept after an end
    /// tag crossed it may be rebuilt anywhere).
    private mutating func doubtClosing(of name: [UInt8]) {
        let keptOfName = formattingHeldByName[name, default: 0] - (positionsByName[name]?.count ?? 0)
        if ScannedTagName.formattingNames.contains(name), keptOfName > 0 {
            markDoubtful(from: 0)
            return
        }
        let lowest = lowestPosition(of: ScannedTagName.closingKind(of: name)) ?? (stack.count - 1)
        markDoubtful(from: max(0, min(lowest, stack.count - 1)))
    }

    /// The tree builder may have closed the elements held from `index` up,
    /// or never inserted them.
    private mutating func markDoubtful(from index: Int) {
        while let last = robustMarks.last, last.index >= index {
            robustMarks.removeLast()
        }
        robustMarks.append((index: index, pushCount: pushCount))
    }

    /// Whether the tree builder has certainly held the element at `index`
    /// from its push on: no event since may have closed it, this scan's
    /// own closes included.
    private func isRobustlyOpen(at index: Int) -> Bool {
        var low = 0
        var high = robustMarks.count
        while low < high {
            let middle = (low + high) / 2
            if robustMarks[middle].index <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return true }
        return stack[index].pushedAt > robustMarks[low - 1].pushCount
    }

    /// Whether the tree builder certainly holds a `name` in table scope.
    private func isCertainlyInTableScope(_ name: [UInt8]) -> Bool {
        guard let index = positionsByName[name]?.last, isRobustlyOpen(at: index),
              let boundaries = ScannedTagName.scopeBoundaries(crossedByEndTagOf: name) else {
            return false
        }
        return !boundaries.contains(where: { (positionsByName[$0]?.last ?? -1) > index })
    }

    /// The formatting elements at `index` and above are no longer certainly
    /// open on the tree builder's stack: popped, or possibly closed.
    private mutating func dropCertainlyOpenFormatting(from index: Int) {
        while let last = certainlyOpenFormatting.last, last.index >= index {
            certainlyOpenFormatting.removeLast()
            updateRebuildCandidates(key: last.key) { $0.certainlyOpenByKey[last.key] -= 1 }
        }
    }

    private mutating func formattingKey(of range: Range<Int>, attributeCount: Int) -> Int {
        let bytesOfTag = Array(bytes[range])
        if let key = formattingKeys[bytesOfTag] {
            return key
        }
        let key = heldByKey.count
        formattingKeys[bytesOfTag] = key
        heldByKey.append(0)
        certainlyOpenByKey.append(0)
        rebuildCostByKey.append(Self.rebuildCost(attributeCount: attributeCount))
        return key
    }

    /// Applies `change` to one key's counts and keeps the capped totals.
    private mutating func updateRebuildCandidates(key: Int, _ change: (inout TokenizingScanner) -> Void) {
        let before = min(heldByKey[key] - certainlyOpenByKey[key], Self.sameFormattingKept)
        let heldBefore = min(heldByKey[key], Self.sameFormattingKept)
        change(&self)
        rebuildableHeld += min(heldByKey[key], Self.sameFormattingKept) - heldBefore
        let after = min(heldByKey[key] - certainlyOpenByKey[key], Self.sameFormattingKept)
        rebuildCandidates += after - before
        rebuildCandidatesCost = Saturating.add(
            rebuildCandidatesCost,
            Saturating.multiply(after - before, rebuildCostByKey[key])
        )
    }

    /// Noah's ark: entries of one name and attributes kept after a marker.
    private static let sameFormattingKept = 3

    /// A formatting element's cost each time SwiftSoup rebuilds it: copying
    /// its attributes searches the copy's for each one (`Attributes.addAll`,
    /// quadratic; a `b` of 300 attributes rebuilt 2,000 times took 2.7 s).
    static func rebuildCost(attributeCount: Int) -> Int {
        Saturating.multiply(attributeCount, attributeCount)
    }

    /// After a token: the text that may follow it and the start tag after
    /// that each rebuild the active formatting elements off the stack
    /// (`reconstructFormattingElements`). Each such element costs a search
    /// of the stack (`onStack`) and its rebuild: 1,000 left-open `b`s below
    /// 1,000 `div`s, rebuilt 500 times, took 12 s. Held ones not certainly
    /// open, at most three of one name and attributes, are all that can be
    /// off the stack and rebuilt.
    private mutating func chargeRebuilds() {
        let candidates = rebuildCandidates
        let cost = rebuildCandidatesCost
        rebuildCandidatesAcrossTokens = Saturating.add(rebuildCandidatesAcrossTokens, Saturating.multiply(candidates, 2))
        rebuildCostAcrossTokens = Saturating.add(rebuildCostAcrossTokens, Saturating.multiply(cost, 2))
    }

    private func innermostIs(_ name: [UInt8]) -> Bool {
        stack.last?.name == name
    }

    private func innermostIs(in names: Set<[UInt8]>) -> Bool {
        stack.last.map { names.contains($0.name) } ?? false
    }

    /// The lowest position of any of `names`, or nil.
    private func lowestPosition(of names: Set<[UInt8]>) -> Int? {
        names.compactMap { positionsByName[$0]?.first }.min()
    }

    /// The highest position of any of `names`, or nil.
    private func highestPosition(of names: Set<[UInt8]>) -> Int? {
        names.compactMap { positionsByName[$0]?.last }.max()
    }

    /// The lowest position of any of `names` at or above `floor`, or nil.
    private func lowestPosition(of names: Set<[UInt8]>, atOrAbove floor: Int) -> Int? {
        names.compactMap { name -> Int? in
            guard let positions = positionsByName[name] else { return nil }
            var low = 0
            var high = positions.count
            while low < high {
                let middle = (low + high) / 2
                if positions[middle] < floor {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low < positions.count ? positions[low] : nil
        }.min()
    }

    /// After a tag the scan did not fully follow, the tree builder may have
    /// closed the element at `lowestTarget` and everything above it. A
    /// formatting element kept after an end tag crossed it may have been
    /// rebuilt anywhere since, so a tag that can close one of its name
    /// marks the whole stack.
    private mutating func markPossiblyClosed(by name: [UInt8], lowestTarget: Int?) {
        let keptOfName = formattingHeldByName[name, default: 0] - (positionsByName[name]?.count ?? 0)
        // Inside a `template` the builder's modes are its own; anything it
        // holds may be closed.
        let template = positionsByName[Self.template]?.first
        if ScannedTagName.formattingNames.contains(name), keptOfName > 0 {
            markPossiblyClosed(from: 0)
        } else if let lowest = [lowestTarget, template].compactMap({ $0 }).min() {
            markPossiblyClosed(from: lowest)
        }
    }

    private static let template = Array("template".utf8)

    /// The tree builder may have closed the elements this stack holds from
    /// `index` up, so none of them is certainly open any more.
    private mutating func markPossiblyClosed(from index: Int) {
        while let last = possiblyClosedMarks.last, last.index >= index {
            possiblyClosedMarks.removeLast()
        }
        possiblyClosedMarks.append((index: index, pushCount: pushCount))
        markDoubtful(from: index)
        dropCertainlyOpenFormatting(from: index)
    }

    /// Open unless an event since its push may have closed it: the latest
    /// mark from at or below its index is the one that covers it.
    private func isCertainlyOpen(at index: Int) -> Bool {
        var low = 0
        var high = possiblyClosedMarks.count
        while low < high {
            let middle = (low + high) / 2
            if possiblyClosedMarks[middle].index <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return true }
        return stack[index].pushedAt > possiblyClosedMarks[low - 1].pushCount
    }

    /// Closes the innermost element where the tree builder always closes it
    /// before inserting `name`. Each rule pops only an element that is the
    /// innermost one, where the builder's own rule (close a `p` in button
    /// scope, close the cell, and so on) is certain to close it too. What
    /// the builder may close beyond that is marked.
    private mutating func closeImpliedElements(before name: [UInt8]) {
        typealias N = ScannedTagName
        // In a table's modes SwiftSoup inserts a `form` without closing a
        // `p` (a table part's fragment holds one open over it), so a `form`
        // only marks the `p` as possibly closed.
        if N.closesParagraph.contains(name), name != N.form, innermostIs(N.p) {
            popInnermostForStartTag()
        }
        if N.headings.contains(name), innermostIs(in: N.headings) {
            popInnermostForStartTag()
        }
        if name == N.li, innermostIs(N.li) {
            popInnermostForStartTag()
        }
        if name == N.dd || name == N.dt, innermostIs(N.dd) || innermostIs(N.dt) {
            popInnermostForStartTag()
        }
        if name == N.td || name == N.th, innermostIs(N.td) || innermostIs(N.th) {
            popInnermostForStartTag()
        }
        if name == N.tr || N.tableSections.contains(name) {
            if innermostIs(N.td) || innermostIs(N.th) {
                popInnermostForStartTag()
            }
            if innermostIs(N.tr) {
                popInnermostForStartTag()
            }
            if N.tableSections.contains(name), innermostIs(in: N.tableSections) {
                popInnermostForStartTag()
            }
        }
        // Outside `select` an `optgroup` closes only an `option`, never
        // another `optgroup` (inside `select` the first scan decides).
        if name == N.option || name == N.optgroup, innermostIs(N.option) {
            popInnermostForStartTag()
        }
        markPossiblyClosed(by: name, lowestTarget: lowestTargetOfStartTag(name))
    }

    /// The lowest element held that the tree builder may close for the
    /// start tag `name`, beyond what `closeImpliedElements` did.
    ///
    /// The builder looks for its target from the current node down and
    /// stops at the first of `rule.stopsAt`; where the highest of those held
    /// is certainly open, it is in the builder's stack too, so nothing below
    /// it is reached. A rule that clears back to its stop closes everything
    /// above that stop.
    private func lowestTargetOfStartTag(_ name: [UInt8]) -> Int? {
        var lowest = ScannedTagName.closingRules(forStartTag: name).compactMap(lowestTarget(of:)).min()
        if ScannedTagName.tableStructure.contains(name), !stack.isEmpty {
            // In the table modes a table part's start tag closes the cell,
            // the row or the section it is in, or clears everything above
            // the table, fostered elements too; in a table part's fragment
            // context everything held. Above a certainly open table, or all.
            let floor: Int
            if !isTableContextFragment, let table = certainlyOpenTable() {
                floor = name == ScannedTagName.table ? table : table + 1
            } else {
                floor = 0
            }
            if floor < stack.count {
                lowest = min(lowest ?? floor, floor)
            }
        }
        return lowest
    }

    /// The highest held `table`, when it is certainly open.
    private func certainlyOpenTable() -> Int? {
        guard let table = positionsByName[ScannedTagName.table]?.last, isCertainlyOpen(at: table) else {
            return nil
        }
        return table
    }

    private func lowestTarget(of rule: ScannedTagName.ClosingRule) -> Int? {
        guard !stack.isEmpty else { return nil }
        if rule.currentNodeOnly {
            // A certainly open innermost element is the builder's current
            // node too (it holds nothing above it but rebuilt formatting).
            return isCertainlyOpen(at: stack.count - 1) ? nil : lowestPosition(of: rule.targets)
        }
        if rule.clearsAboveStop {
            guard !rule.stopsAt.isEmpty else { return 0 }
            guard let highestStop = highestPosition(of: rule.stopsAt) else { return nil }
            let stop = isCertainlyOpen(at: highestStop) ? highestStop : (lowestPosition(of: rule.stopsAt) ?? highestStop)
            return stop + 1 < stack.count ? stop + 1 : nil
        }
        var floor = 0
        if let highestStop = highestPosition(of: rule.stopsAt), isCertainlyOpen(at: highestStop) {
            floor = rule.targets.contains(stack[highestStop].name) ? highestStop : highestStop + 1
        }
        return lowestPosition(of: rule.targets, atOrAbove: floor)
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
            return Tag(name: name, isEndTag: isEndTag, selfClosing: false, end: probe + 1, attributeCount: 0)
        }
        if probe < count, bytes[probe] == 0x2F {
            probe = skipWhitespace(from: probe + 1)
            if probe < count, bytes[probe] == 0x3E {
                return Tag(name: name, isEndTag: isEndTag, selfClosing: true, end: probe + 1, attributeCount: 0)
            }
        }

        let attributes = endOfAttributes(from: index)
        return Tag(
            name: name,
            isEndTag: isEndTag,
            selfClosing: attributes.selfClosing,
            end: attributes.end,
            attributeCount: attributes.attributeCount
        )
    }

    private func skipWhitespace(from start: Int) -> Int {
        var index = start
        while index < count, ScannedTagName.isTokenizerWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    /// From the byte after a tag name to the index after the tag's `>` (nil
    /// at the end of the input), whether `/>` closed it, and how many
    /// attribute names it began.
    private func endOfAttributes(from start: Int) -> (end: Int?, selfClosing: Bool, attributeCount: Int) {
        var index = start
        var state = TagAttributeReading.State.beforeName
        var attributeCount = 0
        while index < count {
            switch TagAttributeReading.step(state, bytes[index]) {
            case let .consume(next, startsAttribute):
                state = next
                index += 1
                if startsAttribute {
                    attributeCount += 1
                }
            case let .reconsume(next):
                state = next
            case let .end(selfClosing):
                return (index + 1, selfClosing, attributeCount)
            }
        }
        return (nil, false, attributeCount)
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
    private mutating func endOfMarkupDeclaration(from start: Int) -> Int? {
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
            // Its content is text, which may end the head.
            if !inHeadNoscript {
                certainlyInHead = false
            }
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
                   ScannedTagName.isASCIIAlpha(bytes[index + 1]),
                   lastTitleEndTagStart < index + 1 {
                    closeElement(named: name)
                    return index
                }
            }
            index += 1
        }
        return nil
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

// MARK: - Work arithmetic

private enum Saturating {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    static func multiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : product
    }
}

// MARK: - Title search cost

/// An upper bound on the bytes SwiftSoup's title end-tag searches read,
/// from the bytes alone.
///
/// In a title's raw text SwiftSoup searches, at every `<` and ASCII letter,
/// from the letter on for `</title`, and where there is none for `</TITLE`
/// (`containsIgnoreCase`). Before the last occurrence of either spelling,
/// every such position is charged that search, whether or not it is in a
/// title: a superset of where SwiftSoup searches. After it, a title's text
/// ends at its first `<` and letter (no end tag follows), so each `<title`
/// there is charged one search of twice the rest. Positions before the first
/// `<title` are not charged: no title's text starts before it.
private enum TitleSearchCost {
    private static let lowercaseEndTag = Array("</title".utf8)
    private static let uppercaseEndTag = Array("</TITLE".utf8)
    private static let startTagName = Array("title".utf8)

    static func bytesRead(in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        let count = bytes.count
        guard let firstTitle = firstTitleStartTag(in: bytes) else { return 0 }
        var nextLowercase = count
        var nextUppercase = count
        var total = 0
        var index = count - 1
        while index >= firstTitle {
            if matches(lowercaseEndTag, in: bytes, at: index) {
                nextLowercase = index
            }
            if matches(uppercaseEndTag, in: bytes, at: index) {
                nextUppercase = index
            }
            if bytes[index] == 0x3C, index + 1 < count, ScannedTagName.isASCIIAlpha(bytes[index + 1]) {
                let position = index + 1
                if nextLowercase < count {
                    total = Saturating.add(total, nextLowercase - position)
                } else if nextUppercase < count {
                    total = Saturating.add(total, (count - position) + (nextUppercase - position))
                } else if isTitleStartTag(in: bytes, at: index) {
                    total = Saturating.add(total, 2 * (count - position))
                }
            }
            index -= 1
        }
        return total
    }

    private static func firstTitleStartTag(in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x3C, isTitleStartTag(in: bytes, at: index) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// `<title` in any case, followed by what ends a tag name or by the end.
    private static func isTitleStartTag(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        let nameStart = index + 1
        let nameEnd = nameStart + startTagName.count
        guard nameEnd <= bytes.count else { return false }
        for offset in 0..<startTagName.count
        where ScannedTagName.lowercasedASCII(bytes[nameStart + offset]) != startTagName[offset] {
            return false
        }
        return nameEnd == bytes.count || ScannedTagName.endsTagName(bytes[nameEnd])
    }

    private static func matches(_ pattern: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
            return false
        }
        return true
    }
}
