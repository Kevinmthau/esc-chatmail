import Foundation

enum LayoutWidthState {
    case fluid
    case nonFluid
}

struct LayoutWidthDeclaration {
    let target: LayoutSelectorTarget
    let state: LayoutWidthState
    let isImportant: Bool
    let specificity: CSSSelectorSpecificity
    let order: Int
    let mediaWidthRange: CSSMediaWidthRange
}

struct ResponsiveMediaWidthDeclarations {
    let mediaWidthRange: CSSMediaWidthRange
    var declarations: [LayoutWidthDeclaration]
}

enum EmailLayoutDetector {
    static func originalFixedLayoutViewportWidth(in html: String) -> Int? {
        let normalizedHTML = html
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "=3D", with: "=", options: .caseInsensitive)
        let liveHTML = removingHTMLComments(from: normalizedHTML)
        let containsResponsiveWidthQuery = CSSParser.containsResponsiveScreenWidthMediaQuery(in: liveHTML)

        let layoutCSSHTML = CSSParser.removingConditionalCSSMediaBlocks(
            from: liveHTML,
            preservingUnconditionalScreenMedia: !containsResponsiveWidthQuery
        )

        let candidates = [
            largestLayoutWidth(in: liveHTML, pattern: #"<table[^>]*?\bwidth\s*=\s*["']?([0-9]{3,4})"#),
            largestLayoutWidth(in: layoutCSSHTML, pattern: #"(?:^|[;{"'=])\s*width\s*:\s*([0-9]{3,4})\s*px"#),
            largestLayoutWidth(in: layoutCSSHTML, pattern: #"(?:^|[;{"'=])\s*min-width\s*:\s*([0-9]{3,4})\s*px"#),
            largestTableMaxLayoutWidth(in: layoutCSSHTML)
        ].compactMap { $0 }

        guard let fixedWidth = candidates.max() else {
            return nil
        }

        if containsResponsiveWidthQuery,
           containsResponsiveFluidLayoutOverride(
               in: liveHTML,
               layoutCSSHTML: layoutCSSHTML,
               fixedWidth: fixedWidth
           ) {
            return nil
        }

        return fixedWidth
    }

    private static func containsResponsiveFluidLayoutOverride(
        in html: String,
        layoutCSSHTML: String,
        fixedWidth: Int
    ) -> Bool {
        let fixedLayoutTargets = fixedLayoutSelectorTargets(
            in: html,
            layoutCSSHTML: layoutCSSHTML,
            fixedWidth: fixedWidth
        )
        guard !fixedLayoutTargets.isEmpty else {
            return false
        }

        let selectorElements = HTMLSelectorMatcher.htmlSelectorElements(in: html)
        var widthDeclarationsByMediaQuery: [String: ResponsiveMediaWidthDeclarations] = [:]
        var widthDeclarationOrder = 0
        var searchStart = html.startIndex

        while let mediaRange = html.range(
            of: "@media",
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            guard let blockStart = html[mediaRange.upperBound...].firstIndex(of: "{"),
                  let blockEnd = CSSParser.matchingClosingBrace(in: html, openingBrace: blockStart) else {
                searchStart = mediaRange.upperBound
                continue
            }

            let mediaPrelude = html[mediaRange.upperBound..<blockStart]
            let queries = mediaPrelude.split(separator: ",", omittingEmptySubsequences: true)
            let responsiveQueries = queries.filter(CSSParser.isResponsiveScreenWidthMediaQuery)
            if !responsiveQueries.isEmpty {
                let blockBody = String(html[html.index(after: blockStart)..<blockEnd])
                for query in responsiveQueries {
                    guard let mediaWidthRange = CSSParser.screenMediaQueryWidthRange(query),
                          mediaWidthRange.canMatchResponsiveLayoutViewport() else {
                        continue
                    }

                    let widthDeclarations = mediaQueryWidthDeclarations(
                        in: blockBody,
                        selectorElements: selectorElements,
                        activeMediaWidthRanges: [mediaWidthRange],
                        order: &widthDeclarationOrder
                    )
                    if !widthDeclarations.isEmpty {
                        let queryKey = normalizedMediaQueryKey(query)
                        if var existingDeclarations = widthDeclarationsByMediaQuery[queryKey] {
                            existingDeclarations.declarations.append(contentsOf: widthDeclarations)
                            widthDeclarationsByMediaQuery[queryKey] = existingDeclarations
                        } else {
                            widthDeclarationsByMediaQuery[queryKey] = ResponsiveMediaWidthDeclarations(
                                mediaWidthRange: mediaWidthRange,
                                declarations: widthDeclarations
                            )
                        }
                    }
                }
            }

            searchStart = html.index(after: blockEnd)
        }

        return widthDeclarationsByMediaQuery.values.contains { mediaDeclarations in
            guard let responsiveSpan = mediaDeclarations.mediaWidthRange.responsiveLayoutViewportSpan() else {
                return false
            }

            return responsiveSpan.allSatisfy { viewportWidth in
                fixedLayoutTargets.allSatisfy { fixedTarget in
                    finalWidthDeclaration(
                        matching: fixedTarget,
                        in: mediaDeclarations.declarations,
                        at: viewportWidth
                    )?.state == .fluid
                }
            }
        }
    }

    private static func normalizedMediaQueryKey(_ query: Substring) -> String {
        String(query).lowercased().filter { !$0.isWhitespace }
    }

    private static func largestTableMaxLayoutWidth(in html: String) -> Int? {
        tableMaxWidthCSSSelectorTargets(in: html, fixedWidth: nil)
            .map { $0.width }
            .max()
    }

    private static func tableMaxWidthCSSSelectorTargets(
        in html: String,
        fixedWidth: Int?
    ) -> [(width: Int, target: LayoutSelectorTarget)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([^{}@]+)\{[^{}]*(?<!-)\bmax-width\s*:\s*([0-9]{3,4})\s*px\b"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let selectorElements = HTMLSelectorMatcher.htmlSelectorElements(in: html)
        let elementTargets = selectorElements.map(\.target)
        let fluidWidthTableTargets = fluidWidthTableTargets(in: html)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).flatMap { match -> [(width: Int, target: LayoutSelectorTarget)] in
            guard let selectorsRange = Range(match.range(at: 1), in: html),
                  let valueRange = Range(match.range(at: 2), in: html),
                  let width = validLayoutWidth(String(html[valueRange])),
                  fixedWidth == nil || fixedWidth == width else {
                return []
            }

            return String(html[selectorsRange]).split(separator: ",").compactMap { selector -> (width: Int, target: LayoutSelectorTarget)? in
                let selector = CSSParser.cssSelectorText(from: String(selector))
                guard let target = tableSelectorTarget(
                    for: selector,
                    selectorElements: selectorElements,
                    elementTargets: elementTargets,
                    fluidWidthTableTargets: fluidWidthTableTargets
                ) else {
                    return nil
                }

                return (width: width, target: target)
            }
        }
    }

    private static func tableSelectorTarget(
        for selector: String,
        selectorElements: [HTMLSelectorElement],
        elementTargets: [LayoutSelectorTarget],
        fluidWidthTableTargets: [LayoutSelectorTarget]
    ) -> LayoutSelectorTarget? {
        guard let target = HTMLSelectorMatcher.selectorTarget(in: selector) else {
            return nil
        }
        let requiresConcreteNonFluidTable = target.tagName != "table"

        if HTMLSelectorMatcher.selectorContainsCombinator(selector) {
            let matchingTables = HTMLSelectorMatcher.htmlElementSelectorTargets(
                matchingComplexSelector: selector,
                in: selectorElements
            )?.filter { $0.tagName == "table" } ?? []
            if let matchingTable = matchingTables.first(where: {
                !requiresConcreteNonFluidTable || !fluidWidthTableTargets.containsTargetMatching($0)
            }) {
                return matchingTable
            }
            if !matchingTables.isEmpty {
                return nil
            }

            return target.tagName == "table" ? target : nil
        }

        let matchingTables = elementTargets.filter { elementTarget in
            elementTarget.tagName == "table"
                && HTMLSelectorMatcher.selectorTarget(target, matches: elementTarget)
        }
        if let matchingTable = matchingTables.first(where: {
            !requiresConcreteNonFluidTable || !fluidWidthTableTargets.containsTargetMatching($0)
        }) {
            return matchingTable
        }
        if !matchingTables.isEmpty {
            return nil
        }

        return target.tagName == "table" ? target : nil
    }

    private static func fluidWidthTableTargets(in html: String) -> [LayoutSelectorTarget] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<table\b(?=[^>]*?\bwidth\s*=)[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range(at: 0), in: html) else {
                return nil
            }

            let tagHTML = String(html[tagRange])
            guard HTMLSelectorMatcher.attributeValue(named: "width", in: tagHTML)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "100%" else {
                return nil
            }

            return HTMLSelectorMatcher.htmlElementSelectorTarget(tagName: "table", tagHTML: tagHTML)
        }
    }

    private static func fixedLayoutSelectorTargets(
        in html: String,
        layoutCSSHTML: String,
        fixedWidth: Int
    ) -> [LayoutSelectorTarget] {
        let fixedTableTargets = fixedTableSelectorTargets(in: html, fixedWidth: fixedWidth)
        if !fixedTableTargets.isEmpty {
            return fixedTableTargets
        }

        return fixedInlineStyleSelectorTargets(in: html, fixedWidth: fixedWidth)
            + fixedCSSSelectorTargets(in: layoutCSSHTML, fixedWidth: fixedWidth)
            + tableMaxWidthCSSSelectorTargets(in: layoutCSSHTML, fixedWidth: fixedWidth).map { $0.target }
    }

    private static func fixedTableSelectorTargets(in html: String, fixedWidth: Int) -> [LayoutSelectorTarget] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<table\b(?=[^>]*?\bwidth\s*=\s*["']?\#(fixedWidth)(?:["'\s>]|[^0-9]))[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range(at: 0), in: html) else {
                return nil
            }

            return HTMLSelectorMatcher.htmlElementSelectorTarget(tagName: "table", tagHTML: String(html[tagRange]))
        }
    }

    private static func fixedInlineStyleSelectorTargets(in html: String, fixedWidth: Int) -> [LayoutSelectorTarget] {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<([A-Za-z][A-Za-z0-9:-]*)\b(?=[^>]*?\bstyle\s*=)[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let widthRegex = try? NSRegularExpression(
            pattern: #"(?<!-)\b(?:width|min-width)\s*:\s*\#(fixedWidth)\s*px\b"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return tagRegex.matches(in: html, range: range).compactMap { match in
            guard let tagNameRange = Range(match.range(at: 1), in: html),
                  let tagRange = Range(match.range(at: 0), in: html) else {
                return nil
            }

            let tagHTML = String(html[tagRange])
            guard let style = HTMLSelectorMatcher.attributeValue(named: "style", in: tagHTML) else {
                return nil
            }

            let styleRange = NSRange(style.startIndex..<style.endIndex, in: style)
            guard widthRegex.firstMatch(in: style, range: styleRange) != nil else {
                return nil
            }

            return HTMLSelectorMatcher.htmlElementSelectorTarget(tagName: String(html[tagNameRange]), tagHTML: tagHTML)
        }
    }

    private static func fixedCSSSelectorTargets(in html: String, fixedWidth: Int) -> [LayoutSelectorTarget] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([^{}@]+)\{[^{}]*(?<!-)\b(?:width|min-width)\s*:\s*\#(fixedWidth)\s*px\b"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let selectorElements = HTMLSelectorMatcher.htmlSelectorElements(in: html)
        let elementTargets = selectorElements.map(\.target)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).flatMap { match -> [LayoutSelectorTarget] in
            guard let selectorsRange = Range(match.range(at: 1), in: html) else {
                return []
            }

            return String(html[selectorsRange]).split(separator: ",").flatMap { selector -> [LayoutSelectorTarget] in
                let selector = CSSParser.cssSelectorText(from: String(selector))
                guard let target = HTMLSelectorMatcher.selectorTarget(in: selector) else {
                    return []
                }
                guard !HTMLSelectorMatcher.selectorContainsCombinator(selector) else {
                    guard let matchingElements = HTMLSelectorMatcher.htmlElementSelectorTargets(
                        matchingComplexSelector: selector,
                        in: selectorElements
                    ) else {
                        return [target]
                    }
                    return matchingElements.isEmpty ? [target] : matchingElements
                }

                let matchingElements = elementTargets.filter { elementTarget in
                    HTMLSelectorMatcher.selectorTarget(target, matches: elementTarget)
                }
                return matchingElements.isEmpty ? [target] : matchingElements
            }
        }
    }

    private static func mediaQueryWidthDeclarations(
        in css: String,
        selectorElements: [HTMLSelectorElement],
        activeMediaWidthRanges: [CSSMediaWidthRange],
        order: inout Int
    ) -> [LayoutWidthDeclaration] {
        var declarations: [LayoutWidthDeclaration] = []
        var currentIndex = css.startIndex

        while let block = CSSParser.nextCSSBlock(in: css, from: currentIndex) {
            let prelude = block.prelude.trimmingCharacters(in: .whitespacesAndNewlines)
            if prelude.hasPrefix("@") {
                if let nestedMediaWidthRanges = nestedMediaWidthRanges(
                    for: prelude,
                    activeMediaWidthRanges: activeMediaWidthRanges
                ) {
                    declarations += mediaQueryWidthDeclarations(
                        in: block.body,
                        selectorElements: selectorElements,
                        activeMediaWidthRanges: nestedMediaWidthRanges,
                        order: &order
                    )
                }
            } else {
                let selectorTexts = prelude.split(separator: ",").map {
                    CSSParser.cssSelectorText(from: String($0))
                }
                let widthStates = widthStates(in: block.body)

                for widthState in widthStates {
                    order += 1
                    for selector in selectorTexts {
                        let targets = HTMLSelectorMatcher.selectorTargets(in: selector, matching: selectorElements)
                        let specificity = CSSParser.cssSelectorSpecificity(in: selector)
                        for activeMediaWidthRange in activeMediaWidthRanges {
                            declarations += targets.map { target in
                                LayoutWidthDeclaration(
                                    target: target,
                                    state: widthState.state,
                                    isImportant: widthState.isImportant,
                                    specificity: specificity,
                                    order: order,
                                    mediaWidthRange: activeMediaWidthRange
                                )
                            }
                        }
                    }
                }
            }

            currentIndex = block.nextIndex
        }

        return declarations
    }

    private static func nestedMediaWidthRanges(
        for prelude: String,
        activeMediaWidthRanges: [CSSMediaWidthRange]
    ) -> [CSSMediaWidthRange]? {
        let trimmedPrelude = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedPrelude = trimmedPrelude.lowercased()
        guard lowercasedPrelude.hasPrefix("@media") else {
            return nil
        }

        let mediaPreludeStart = trimmedPrelude.index(trimmedPrelude.startIndex, offsetBy: "@media".count)
        let nestedMediaRanges = trimmedPrelude[mediaPreludeStart...]
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap(CSSParser.screenMediaQueryWidthRange)

        let matchingRanges = activeMediaWidthRanges.flatMap { activeRange in
            nestedMediaRanges.compactMap { nestedRange in
                activeRange.intersection(with: nestedRange)
            }
        }.filter { $0.canMatchResponsiveLayoutViewport() }

        return matchingRanges.isEmpty ? nil : matchingRanges
    }

    private static func widthStates(in declarationBody: String) -> [(state: LayoutWidthState, isImportant: Bool)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!-)\bwidth\s*:\s*([^;{}]+)"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(declarationBody.startIndex..<declarationBody.endIndex, in: declarationBody)
        return regex.matches(in: declarationBody, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: declarationBody) else {
                return nil
            }

            let value = String(declarationBody[valueRange])
            return (
                state: isFluidWidthValue(value) ? .fluid : .nonFluid,
                isImportant: value.range(of: "!important", options: .caseInsensitive) != nil
            )
        }
    }

    private static func isFluidWidthValue(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "!important", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = try? NSRegularExpression(
            pattern: #"^100\s*%$"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return regex.firstMatch(in: normalized, range: range) != nil
    }

    private static func finalWidthDeclaration(
        matching fixedTarget: LayoutSelectorTarget,
        in declarations: [LayoutWidthDeclaration],
        at viewportWidth: Int
    ) -> LayoutWidthDeclaration? {
        declarations.reduce(nil) { currentWinner, declaration in
            guard declaration.mediaWidthRange.contains(viewportWidth) else {
                return currentWinner
            }

            guard HTMLSelectorMatcher.selectorTarget(declaration.target, matches: fixedTarget) else {
                return currentWinner
            }

            guard let currentWinner else {
                return declaration
            }

            return widthDeclaration(declaration, overrides: currentWinner) ? declaration : currentWinner
        }
    }

    private static func widthDeclaration(
        _ declaration: LayoutWidthDeclaration,
        overrides currentWinner: LayoutWidthDeclaration
    ) -> Bool {
        if declaration.isImportant != currentWinner.isImportant {
            return declaration.isImportant
        }
        if declaration.specificity != currentWinner.specificity {
            return declaration.specificity > currentWinner.specificity
        }
        return declaration.order >= currentWinner.order
    }

    private static func removingHTMLComments(from html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->"#,
            options: []
        ) else {
            return html
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    private static func largestLayoutWidth(in html: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match -> Int? in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: html),
                  let width = validLayoutWidth(String(html[valueRange])) else {
                return nil
            }

            return width
        }.max()
    }

    private static func validLayoutWidth(_ text: String) -> Int? {
        guard let width = Int(text),
              width >= HTMLDisplayWrapper.minimumFixedLayoutViewportWidth,
              width <= HTMLDisplayWrapper.maximumFixedLayoutViewportWidth else {
            return nil
        }

        return width
    }
}

private extension Array where Element == LayoutSelectorTarget {
    func containsTargetMatching(_ target: LayoutSelectorTarget) -> Bool {
        contains { candidate in
            HTMLSelectorMatcher.selectorTarget(candidate, matches: target)
                && HTMLSelectorMatcher.selectorTarget(target, matches: candidate)
        }
    }
}
