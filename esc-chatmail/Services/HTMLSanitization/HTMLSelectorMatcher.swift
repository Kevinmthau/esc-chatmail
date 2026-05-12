import Foundation

struct LayoutSelectorTarget {
    let tagName: String?
    let id: String?
    let classNames: Set<String>
    let classAttributeValue: String?
    let exactClassAttributeValues: Set<String>

    init(
        tagName: String?,
        id: String?,
        classNames: Set<String>,
        classAttributeValue: String? = nil,
        exactClassAttributeValues: Set<String> = []
    ) {
        self.tagName = tagName
        self.id = id
        self.classNames = classNames
        self.classAttributeValue = classAttributeValue
        self.exactClassAttributeValues = exactClassAttributeValues
    }
}

enum LayoutSelectorCombinator {
    case descendant
    case child
    case adjacentSibling
    case generalSibling
}

struct LayoutSelectorPart {
    let target: LayoutSelectorTarget
    let previousCombinator: LayoutSelectorCombinator?
}

struct HTMLSelectorElement {
    let target: LayoutSelectorTarget
    let ancestors: [Int]
    let previousSiblingIndex: Int?
}

enum HTMLSelectorMatcher {
    static func htmlSelectorElements(in html: String) -> [HTMLSelectorElement] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\s*(/)?\s*([A-Za-z][A-Za-z0-9:-]*)\b[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        var elements: [HTMLSelectorElement] = []
        var stack: [Int] = []
        var lastChildIndexStack: [Int?] = [nil]
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let tagNameRange = Range(match.range(at: 2), in: html),
                  let tagRange = Range(match.range(at: 0), in: html) else {
                continue
            }

            let tagHTML = String(html[tagRange])
            let tagName = String(html[tagNameRange]).lowercased()
            if Range(match.range(at: 1), in: html) != nil {
                if let index = stack.lastIndex(where: { elements[$0].target.tagName == tagName }) {
                    stack.removeSubrange(index...)
                    lastChildIndexStack.removeSubrange((index + 1)..<lastChildIndexStack.count)
                }
                continue
            }

            let elementTarget = htmlElementSelectorTarget(
                tagName: tagName,
                tagHTML: tagHTML
            )
            let previousSiblingIndex = lastChildIndexStack.last.flatMap { $0 }
            let elementIndex = elements.count
            elements.append(HTMLSelectorElement(
                target: elementTarget,
                ancestors: stack,
                previousSiblingIndex: previousSiblingIndex
            ))
            lastChildIndexStack[lastChildIndexStack.count - 1] = elementIndex

            if !isSelfClosingHTMLElement(tagName: tagName, tagHTML: tagHTML) {
                stack.append(elementIndex)
                lastChildIndexStack.append(nil)
            }
        }

        return elements
    }

    static func htmlElementSelectorTarget(tagName: String, tagHTML: String) -> LayoutSelectorTarget {
        let id = attributeValue(named: "id", in: tagHTML)
        let classAttributeValue = attributeValue(named: "class", in: tagHTML)
        let classNames = Set(
            classAttributeValue?
                .split { $0.isWhitespace }
                .map(String.init) ?? []
        )

        return LayoutSelectorTarget(
            tagName: tagName.lowercased(),
            id: id,
            classNames: classNames,
            classAttributeValue: classAttributeValue
        )
    }

    static func selectorTarget(in selector: String) -> LayoutSelectorTarget? {
        let compound = selector
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "~", with: " ")
            .split { $0.isWhitespace }
            .last
            .map(String.init) ?? selector

        let tagName = firstRegexCapture(
            in: compound,
            pattern: #"^(?:[A-Za-z_][A-Za-z0-9_-]*\|)?([A-Za-z][A-Za-z0-9_-]*)"#
        )?.lowercased()
        let id = firstRegexCapture(in: compound, pattern: #"#([A-Za-z_][A-Za-z0-9_-]*)"#)
        let exactClassAttributeValues = Set(classAttributeSelectorValues(in: compound))
        let classNames = Set(regexCaptures(in: compound, pattern: #"\.([A-Za-z_][A-Za-z0-9_-]*)"#)
            + exactClassAttributeValues.flatMap { $0.split { $0.isWhitespace }.map(String.init) })

        guard tagName != nil || id != nil || !classNames.isEmpty || !exactClassAttributeValues.isEmpty else {
            return nil
        }

        return LayoutSelectorTarget(
            tagName: tagName,
            id: id,
            classNames: classNames,
            exactClassAttributeValues: exactClassAttributeValues
        )
    }

    static func selectorTarget(
        _ target: LayoutSelectorTarget,
        matches fixedTarget: LayoutSelectorTarget
    ) -> Bool {
        if let targetTagName = target.tagName,
           let fixedTagName = fixedTarget.tagName,
           targetTagName != fixedTagName {
            return false
        }

        if let targetID = target.id {
            guard fixedTarget.id == targetID else {
                return false
            }
        }

        for classAttributeValue in target.exactClassAttributeValues {
            guard exactClassAttributeValue(classAttributeValue, matches: fixedTarget) else {
                return false
            }
        }

        guard target.classNames.isSubset(of: fixedTarget.classNames) else {
            return false
        }

        if target.id != nil || !target.classNames.isEmpty || !target.exactClassAttributeValues.isEmpty {
            return true
        }

        return target.tagName != nil && fixedTarget.tagName == target.tagName
    }

    static func selectorContainsCombinator(_ selector: String) -> Bool {
        var previousOutsideAttributeWasWhitespace = false
        var isInsideAttributeSelector = false
        var quoteCharacter: Character?

        for character in selector {
            if let activeQuote = quoteCharacter {
                if character == activeQuote {
                    quoteCharacter = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quoteCharacter = character
                continue
            }

            if character == "[" {
                isInsideAttributeSelector = true
                previousOutsideAttributeWasWhitespace = false
                continue
            }

            if character == "]" {
                isInsideAttributeSelector = false
                previousOutsideAttributeWasWhitespace = false
                continue
            }

            guard !isInsideAttributeSelector else {
                continue
            }

            if character == ">" || character == "+" || character == "~" {
                return true
            }

            if character.isWhitespace {
                previousOutsideAttributeWasWhitespace = true
                continue
            }

            if previousOutsideAttributeWasWhitespace {
                return true
            }
            previousOutsideAttributeWasWhitespace = false
        }

        return false
    }

    static func htmlElementSelectorTargets(
        matchingComplexSelector selector: String,
        in elements: [HTMLSelectorElement]
    ) -> [LayoutSelectorTarget]? {
        guard let selectorParts = complexSelectorParts(in: selector), selectorParts.count > 1 else {
            return nil
        }

        return elements.indices.compactMap { index in
            htmlSelectorElement(at: index, in: elements, matches: selectorParts) ? elements[index].target : nil
        }
    }

    static func selectorTargets(
        in selectors: String,
        matching elements: [HTMLSelectorElement]
    ) -> [LayoutSelectorTarget] {
        selectors.split(separator: ",").flatMap { selector -> [LayoutSelectorTarget] in
            let selector = CSSParser.cssSelectorText(from: String(selector))
            guard selectorContainsCombinator(selector) else {
                return selectorTarget(in: selector).map { [$0] } ?? []
            }

            guard let matchingElements = htmlElementSelectorTargets(
                matchingComplexSelector: selector,
                in: elements
            ) else {
                return []
            }
            return matchingElements
        }
    }

    static func attributeValue(named name: String, in tagHTML: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(tagHTML.startIndex..<tagHTML.endIndex, in: tagHTML)
        guard let match = regex.firstMatch(in: tagHTML, range: range) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard let valueRange = Range(match.range(at: index), in: tagHTML) else {
                continue
            }

            return String(tagHTML[valueRange])
        }

        return nil
    }

    private static func htmlSelectorElement(
        at elementIndex: Int,
        in elements: [HTMLSelectorElement],
        matches selectorParts: [LayoutSelectorPart]
    ) -> Bool {
        let element = elements[elementIndex]
        guard let lastPart = selectorParts.last,
              selectorTarget(lastPart.target, matches: element.target) else {
            return false
        }

        var currentElementIndex = elementIndex
        var ancestorEndIndex = element.ancestors.count
        for partIndex in stride(from: selectorParts.count - 2, through: 0, by: -1) {
            let part = selectorParts[partIndex]
            let combinator = selectorParts[partIndex + 1].previousCombinator ?? .descendant

            switch combinator {
            case .child:
                guard ancestorEndIndex > 0 else {
                    return false
                }

                let parentIndex = ancestorEndIndex - 1
                let parentElementIndex = elements[currentElementIndex].ancestors[parentIndex]
                guard selectorTarget(part.target, matches: elements[parentElementIndex].target) else {
                    return false
                }
                ancestorEndIndex = parentIndex
                currentElementIndex = parentElementIndex

            case .descendant:
                guard let ancestorIndex = matchingAncestorPosition(
                    for: part.target,
                    before: ancestorEndIndex,
                    in: elements[currentElementIndex].ancestors,
                    elements: elements
                ) else {
                    return false
                }
                currentElementIndex = elements[currentElementIndex].ancestors[ancestorIndex]
                ancestorEndIndex = ancestorIndex

            case .adjacentSibling:
                guard let siblingIndex = elements[currentElementIndex].previousSiblingIndex else {
                    return false
                }

                guard selectorTarget(part.target, matches: elements[siblingIndex].target) else {
                    return false
                }
                currentElementIndex = siblingIndex

            case .generalSibling:
                guard let siblingIndex = matchingPreviousSiblingIndex(
                    for: part.target,
                    from: elements[currentElementIndex].previousSiblingIndex,
                    in: elements
                ) else {
                    return false
                }
                currentElementIndex = siblingIndex
            }
        }

        return true
    }

    private static func matchingAncestorPosition(
        for target: LayoutSelectorTarget,
        before endIndex: Int,
        in ancestors: [Int],
        elements: [HTMLSelectorElement]
    ) -> Int? {
        guard endIndex > 0 else {
            return nil
        }

        for index in stride(from: endIndex - 1, through: 0, by: -1) {
            if selectorTarget(target, matches: elements[ancestors[index]].target) {
                return index
            }
        }

        return nil
    }

    private static func matchingPreviousSiblingIndex(
        for target: LayoutSelectorTarget,
        from siblingIndex: Int?,
        in elements: [HTMLSelectorElement]
    ) -> Int? {
        var index = siblingIndex
        while let currentIndex = index {
            if selectorTarget(target, matches: elements[currentIndex].target) {
                return currentIndex
            }
            index = elements[currentIndex].previousSiblingIndex
        }

        return nil
    }

    private static func complexSelectorParts(in selector: String) -> [LayoutSelectorPart]? {
        var parts: [LayoutSelectorPart] = []
        var current = ""
        var pendingCombinator: LayoutSelectorCombinator?
        var hasWhitespaceAfterCurrent = false
        var isInsideAttributeSelector = false
        var parenthesisDepth = 0
        var quoteCharacter: Character?

        func appendCurrentPart() -> Bool {
            let compound = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current.removeAll(keepingCapacity: true)
            guard !compound.isEmpty else {
                return true
            }
            guard let target = selectorTarget(in: compound) else {
                return false
            }

            parts.append(LayoutSelectorPart(
                target: target,
                previousCombinator: parts.isEmpty ? nil : pendingCombinator ?? .descendant
            ))
            pendingCombinator = nil
            return true
        }

        for character in selector {
            if let activeQuote = quoteCharacter {
                current.append(character)
                if character == activeQuote {
                    quoteCharacter = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                current.append(character)
                quoteCharacter = character
                continue
            }

            if character == "[" {
                current.append(character)
                isInsideAttributeSelector = true
                continue
            }

            if character == "]" {
                current.append(character)
                isInsideAttributeSelector = false
                continue
            }

            if !isInsideAttributeSelector {
                if character == "(" {
                    parenthesisDepth += 1
                    current.append(character)
                    continue
                }

                if character == ")" {
                    parenthesisDepth = max(0, parenthesisDepth - 1)
                    current.append(character)
                    continue
                }
            }

            if isInsideAttributeSelector || parenthesisDepth > 0 {
                current.append(character)
                continue
            }

            if character == "+" || character == "~" {
                guard appendCurrentPart() else {
                    return nil
                }
                pendingCombinator = character == "+" ? .adjacentSibling : .generalSibling
                hasWhitespaceAfterCurrent = false
                continue
            }

            if character == ">" {
                guard appendCurrentPart() else {
                    return nil
                }
                pendingCombinator = .child
                hasWhitespaceAfterCurrent = false
                continue
            }

            if character.isWhitespace {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasWhitespaceAfterCurrent = true
                }
                continue
            }

            if hasWhitespaceAfterCurrent {
                guard appendCurrentPart() else {
                    return nil
                }
                pendingCombinator = .descendant
                hasWhitespaceAfterCurrent = false
            }

            current.append(character)
        }

        guard appendCurrentPart() else {
            return nil
        }

        return parts
    }

    private static func isSelfClosingHTMLElement(tagName: String, tagHTML: String) -> Bool {
        let voidElementNames: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
            "meta", "param", "source", "track", "wbr"
        ]

        return voidElementNames.contains(tagName)
            || tagHTML.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>")
    }

    private static func exactClassAttributeValue(
        _ classAttributeValue: String,
        matches fixedTarget: LayoutSelectorTarget
    ) -> Bool {
        if fixedTarget.classAttributeValue == classAttributeValue
            || fixedTarget.exactClassAttributeValues.contains(classAttributeValue) {
            return true
        }

        let exactClassNames = Set(classAttributeValue.split { $0.isWhitespace }.map(String.init))
        return !exactClassNames.isEmpty
            && fixedTarget.classAttributeValue == nil
            && fixedTarget.exactClassAttributeValues.isEmpty
            && fixedTarget.classNames == exactClassNames
    }

    private static func classAttributeSelectorValues(in selector: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\s*class\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\]\s]+))\s*(?:[iIsS])?\]"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        return regex.matches(in: selector, range: range).flatMap { match -> [String] in
            for index in 1..<match.numberOfRanges {
                guard let valueRange = Range(match.range(at: index), in: selector) else {
                    continue
                }

                return [String(selector[valueRange])]
            }

            return []
        }
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        regexCaptures(in: text, pattern: pattern).first
    }

    private static func regexCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                return nil
            }

            return String(text[valueRange])
        }
    }
}
