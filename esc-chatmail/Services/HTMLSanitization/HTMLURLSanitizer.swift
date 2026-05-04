import Foundation

/// Handles URL sanitization within HTML content
struct HTMLURLSanitizer {
    private static let allowedProtocols: Set<String> = [
        "http", "https", "mailto", "tel", "cid"
    ]

    /// Dangerous protocols that should always be blocked
    private static let dangerousProtocols: Set<String> = [
        "javascript", "vbscript", "data"  // data: handled separately for images
    ]

    private struct URLAttribute {
        let name: String
        let lowercasedName: String
        let fullRange: NSRange
        let valueRange: NSRange
    }

    private enum TagScanState {
        case tagName
        case beforeAttributeName
        case attributeName
        case afterAttributeName
        case beforeAttributeValue
        case quotedAttributeValue(Character)
        case unquotedAttributeValue
    }

    private static let modernImageFormatQueryHints: [(key: String, riskyValues: Set<String>, replacement: String)] = [
        ("format", ["auto", "avif", "webp"], "jpeg"),
        ("fm", ["avif", "webp"], "jpg")
    ]

    // Safe image MIME types for data URLs (excludes SVG which can contain scripts)
    private static let dataURLRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "^data:image\\/(png|jpeg|jpg|gif|webp|bmp|x-icon|vnd\\.microsoft\\.icon)(;base64)?,",
            options: .caseInsensitive
        )
    }()

    /// Regex to match Cloudflare cdn-cgi image URLs with format=auto
    /// These URLs can return AVIF which iOS may fail to decode
    private static let cloudflareCDNRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(/cdn-cgi/image/[^"']*?)format=auto([^"']*)"#,
            options: []
        )
    }()

    // Pre-compiled regex for HTML entity decoding (performance optimization)
    // swiftlint:disable:next force_try
    private static let decimalEntityRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "&#(\\d+);", options: .caseInsensitive)
    }()

    // swiftlint:disable:next force_try
    private static let hexEntityRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: .caseInsensitive)
    }()

    /// Sanitizes href and src attributes in HTML
    func sanitizeURLs(_ html: String, rewriteModernFormatQueryHints: Bool = true) -> String {
        var result = html

        result = sanitizeURLAttributes(
            result,
            rewriteModernFormatQueryHints: rewriteModernFormatQueryHints
        )

        // Rewrite Cloudflare CDN image URLs to avoid AVIF decoding issues
        result = rewriteCloudflareCDNImageURLs(result)

        return result
    }

    private func sanitizeURLAttributes(_ html: String, rewriteModernFormatQueryHints: Bool) -> String {
        let replacements = urlAttributes(in: html).compactMap { attribute -> (NSRange, String)? in
            guard let valueRange = Range(attribute.valueRange, in: html) else {
                return nil
            }

            let url = String(html[valueRange])

            if isHrefAttribute(attribute.lowercasedName) {
                return isURLSafe(url) ? nil : (attribute.fullRange, "\(attribute.name)=\"#\"")
            }

            switch attribute.lowercasedName {
            case "src":
                guard let replacement = sanitizedSrcReplacement(
                    for: url,
                    rewriteModernFormatQueryHints: rewriteModernFormatQueryHints
                ) else {
                    return nil
                }
                return (attribute.fullRange, replacement)
            default:
                return nil
            }
        }

        var result = html
        for replacement in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            guard let range = Range(replacement.0, in: result) else {
                continue
            }
            result.replaceSubrange(range, with: replacement.1)
        }
        return result
    }

    private func sanitizedSrcReplacement(
        for rawURL: String,
        rewriteModernFormatQueryHints: Bool
    ) -> String? {
        let transparentPixel = "src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\""
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedURL = HTMLEntityDecoder.decode(url)

        // Skip empty URLs
        if url.isEmpty {
            return transparentPixel
        }

        // Normalize URL to catch bypass attempts
        let normalized = normalizeURL(decodedURL)

        // Block dangerous protocols (javascript:, vbscript:, and unsafe data: URLs)
        if normalized.hasPrefix("javascript:") || normalized.hasPrefix("vbscript:") {
            return transparentPixel
        } else if normalized.hasPrefix("data:") && !isDataURL(normalized) {
            // Block non-image data URLs (e.g., data:text/html)
            return transparentPixel
        } else if rewriteModernFormatQueryHints,
                  let rewrittenURL = rewriteModernImageFormatHints(in: decodedURL),
                  rewrittenURL != decodedURL {
            let escapedURL = htmlAttributeEscaped(rewrittenURL)
            return "src=\"\(escapedURL)\""
        }

        // cid: URLs are preserved - they'll be handled by CIDSchemeHandler
        // Allow all other URLs including tracking pixels and newsletter images
        return nil
    }

    private func urlAttributes(in html: String) -> [URLAttribute] {
        var attributes: [URLAttribute] = []
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                index = html.index(after: index)
                continue
            }

            if html[index...].hasPrefix("<!--") {
                guard let commentEnd = html[index...].range(of: "-->") else {
                    break
                }
                index = commentEnd.upperBound
                continue
            }

            let tagBodyStart = html.index(after: index)
            guard let tagEnd = tagEndIndex(in: html, from: tagBodyStart) else {
                break
            }

            attributes.append(contentsOf: urlAttributes(inTag: tagBodyStart..<tagEnd, html: html))
            index = html.index(after: tagEnd)
        }

        return attributes
    }

    private func tagEndIndex(in html: String, from startIndex: String.Index) -> String.Index? {
        var index = startIndex
        var state: TagScanState = .tagName

        while index < html.endIndex {
            let character = html[index]
            switch state {
            case .tagName:
                if character == ">" {
                    return index
                } else if character.isWhitespace {
                    state = .beforeAttributeName
                }
            case .beforeAttributeName:
                if character == ">" {
                    return index
                } else if character.isWhitespace || character == "/" {
                    break
                } else {
                    state = .attributeName
                }
            case .attributeName:
                if character == ">" {
                    return index
                } else if character == "=" {
                    state = .beforeAttributeValue
                } else if character.isWhitespace || character == "/" {
                    state = .afterAttributeName
                }
            case .afterAttributeName:
                if character == ">" {
                    return index
                } else if character == "=" {
                    state = .beforeAttributeValue
                } else if character.isWhitespace || character == "/" {
                    break
                } else {
                    state = .attributeName
                }
            case .beforeAttributeValue:
                if character == ">" {
                    return index
                } else if character.isWhitespace {
                    break
                } else if character == "\"" || character == "'" {
                    state = .quotedAttributeValue(character)
                } else {
                    state = .unquotedAttributeValue
                }
            case .quotedAttributeValue(let quote):
                if character == quote {
                    state = .beforeAttributeName
                }
            case .unquotedAttributeValue:
                if character == ">" {
                    return index
                } else if character.isWhitespace {
                    state = .beforeAttributeName
                }
            }
            index = html.index(after: index)
        }

        return nil
    }

    private func urlAttributes(inTag tagRange: Range<String.Index>, html: String) -> [URLAttribute] {
        var attributes: [URLAttribute] = []
        var index = skipTagName(in: html, from: tagRange.lowerBound, to: tagRange.upperBound)

        while index < tagRange.upperBound {
            index = skipWhitespace(in: html, from: index, to: tagRange.upperBound)
            guard index < tagRange.upperBound else { break }

            if html[index] == "/" {
                index = html.index(after: index)
                continue
            }

            let attributeStart = index
            while index < tagRange.upperBound,
                  !isAttributeNameTerminator(html[index]) {
                index = html.index(after: index)
            }

            guard attributeStart < index else {
                index = html.index(after: index)
                continue
            }

            let attributeName = String(html[attributeStart..<index])
            index = skipWhitespace(in: html, from: index, to: tagRange.upperBound)

            guard index < tagRange.upperBound, html[index] == "=" else {
                continue
            }

            index = html.index(after: index)
            index = skipWhitespace(in: html, from: index, to: tagRange.upperBound)

            let valueStart: String.Index
            let valueEnd: String.Index
            let fullEnd: String.Index

            if index < tagRange.upperBound, html[index] == "\"" || html[index] == "'" {
                let quote = html[index]
                valueStart = html.index(after: index)
                valueEnd = quotedValueEnd(in: html, from: valueStart, quote: quote, to: tagRange.upperBound)
                fullEnd = valueEnd < tagRange.upperBound ? html.index(after: valueEnd) : valueEnd
            } else {
                valueStart = index
                valueEnd = unquotedValueEnd(in: html, from: valueStart, to: tagRange.upperBound)
                fullEnd = valueEnd
            }

            let lowercasedName = attributeName.lowercased()
            if isHrefAttribute(lowercasedName) || lowercasedName == "src" {
                attributes.append(
                    URLAttribute(
                        name: attributeName,
                        lowercasedName: lowercasedName,
                        fullRange: NSRange(attributeStart..<fullEnd, in: html),
                        valueRange: NSRange(valueStart..<valueEnd, in: html)
                    )
                )
            }

            index = fullEnd
        }

        return attributes
    }

    private func isHrefAttribute(_ lowercasedName: String) -> Bool {
        lowercasedName == "href" || lowercasedName.hasSuffix(":href")
    }

    private func skipTagName(
        in html: String,
        from startIndex: String.Index,
        to endIndex: String.Index
    ) -> String.Index {
        var index = startIndex
        while index < endIndex,
              !html[index].isWhitespace,
              html[index] != "/" {
            index = html.index(after: index)
        }
        return index
    }

    private func skipWhitespace(
        in html: String,
        from startIndex: String.Index,
        to endIndex: String.Index
    ) -> String.Index {
        var index = startIndex
        while index < endIndex, html[index].isWhitespace {
            index = html.index(after: index)
        }
        return index
    }

    private func isAttributeNameTerminator(_ character: Character) -> Bool {
        character.isWhitespace || character == "=" || character == "/" || character == ">"
    }

    private func quotedValueEnd(
        in html: String,
        from startIndex: String.Index,
        quote: Character,
        to endIndex: String.Index
    ) -> String.Index {
        var index = startIndex
        while index < endIndex, html[index] != quote {
            index = html.index(after: index)
        }
        return index
    }

    private func unquotedValueEnd(
        in html: String,
        from startIndex: String.Index,
        to endIndex: String.Index
    ) -> String.Index {
        var index = startIndex
        while index < endIndex, !html[index].isWhitespace {
            index = html.index(after: index)
        }
        return index
    }

    /// Normalizes a URL by decoding percent-encoding, HTML entities, and removing control characters
    /// This prevents bypass attempts like `java%73cript:` or `&#106;avascript:`
    private func normalizeURL(_ url: String) -> String {
        var result = url

        // Step 1: Decode percent-encoding (may need multiple passes for double-encoding)
        var previousResult = ""
        var iterations = 0
        while previousResult != result && iterations < 3 {
            previousResult = result
            if let decoded = result.removingPercentEncoding {
                result = decoded
            }
            iterations += 1
        }

        // Step 2: Decode HTML entities (numeric and named)
        result = decodeHTMLEntities(result)

        // Step 3: Remove whitespace and control characters within protocol portion
        // This prevents bypasses like "java\nscript:" or "java\tscript:"
        result = removeControlCharactersFromProtocol(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Decodes HTML entities in URL strings
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        // Decode numeric entities (&#106; -> j, &#x6A; -> j)
        // Decimal entities
        let decimalRange = NSRange(result.startIndex..., in: result)
        let decimalMatches = Self.decimalEntityRegex.matches(in: result, range: decimalRange)
        for match in decimalMatches.reversed() {
            if let codeRange = Range(match.range(at: 1), in: result),
               let fullRange = Range(match.range, in: result),
               let codePoint = Int(result[codeRange]),
               let scalar = Unicode.Scalar(codePoint) {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        // Hex entities (&#x6A; -> j)
        let hexRange = NSRange(result.startIndex..., in: result)
        let hexMatches = Self.hexEntityRegex.matches(in: result, range: hexRange)
        for match in hexMatches.reversed() {
            if let codeRange = Range(match.range(at: 1), in: result),
               let fullRange = Range(match.range, in: result),
               let codePoint = Int(result[codeRange], radix: 16),
               let scalar = Unicode.Scalar(codePoint) {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }

    /// Removes control characters and whitespace from the protocol portion of a URL
    private func removeControlCharactersFromProtocol(_ url: String) -> String {
        // Find the colon that separates protocol from the rest
        guard let colonIndex = url.firstIndex(of: ":") else {
            return url
        }

        // Extract and clean the protocol portion
        let protocolPart = url[..<colonIndex]
        let cleanProtocol = protocolPart.filter { char in
            // Only allow alphanumeric characters in protocol
            char.isLetter || char.isNumber
        }

        let rest = url[colonIndex...]
        return String(cleanProtocol) + String(rest)
    }

    /// Checks if a URL is safe to include
    func isURLSafe(_ url: String) -> Bool {
        // Normalize URL to prevent bypass attempts
        let normalized = normalizeURL(url)

        // Extract protocol from normalized URL
        if let colonIndex = normalized.firstIndex(of: ":") {
            let proto = String(normalized[..<colonIndex])

            // Block dangerous protocols
            if Self.dangerousProtocols.contains(proto) {
                // Special case: allow data: URLs for images only
                if proto == "data" {
                    return isDataURL(normalized)
                }
                return false
            }

            // Allow known safe protocols
            if Self.allowedProtocols.contains(proto) {
                return true
            }

            // Block unknown protocols
            return false
        }

        // Allow relative URLs
        if normalized.hasPrefix("/") || normalized.hasPrefix("#") || normalized.hasPrefix("?") {
            return true
        }

        // Allow URLs without protocol (will be treated as relative)
        if !normalized.contains(":") {
            return true
        }

        return false
    }

    /// Validates that a data URL is a safe image format
    func isDataURL(_ url: String) -> Bool {
        return Self.dataURLRegex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    private func rewriteModernImageFormatHints(in urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return nil
        }

        var rewrittenItems = queryItems
        var didRewrite = false

        for index in rewrittenItems.indices {
            guard let rawValue = rewrittenItems[index].value?.lowercased() else {
                continue
            }

            for hint in Self.modernImageFormatQueryHints where rewrittenItems[index].name.caseInsensitiveCompare(hint.key) == .orderedSame {
                if hint.riskyValues.contains(rawValue) {
                    rewrittenItems[index].value = hint.replacement
                    didRewrite = true
                }
            }
        }

        guard didRewrite else { return nil }

        var rewrittenComponents = components
        rewrittenComponents.queryItems = rewrittenItems
        return rewrittenComponents.string
    }

    private func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Rewrites Cloudflare cdn-cgi image URLs to use JPEG format instead of auto
    ///
    /// Cloudflare's image resizing service (`/cdn-cgi/image/`) with `format=auto` can return
    /// AVIF images when the browser advertises support. WKWebView advertises AVIF support,
    /// but iOS fails to decode some AVIF images with error: `'AVIF'-_reader->initImage[0] failed`
    ///
    /// This method replaces `format=auto` with `format=jpeg` for reliable image rendering.
    private func rewriteCloudflareCDNImageURLs(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        return Self.cloudflareCDNRegex.stringByReplacingMatches(
            in: html,
            options: [],
            range: range,
            withTemplate: "$1format=jpeg$2"
        )
    }
}
