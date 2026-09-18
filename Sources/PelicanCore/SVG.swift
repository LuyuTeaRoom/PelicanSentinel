import Foundation

/// Errors raised while extracting or validating model-produced SVG.
public enum SVGError: Error, Equatable, LocalizedError, Sendable {
    case emptyResponse
    case svgNotFound
    case malformed
    case unsafeContent
    case tooLarge
    case tooComplex

    public var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The SVG response is empty."
        case .svgNotFound: return "No complete SVG was found in the response."
        case .malformed: return "The SVG contains invalid XML."
        case .unsafeContent: return "The SVG contains content that cannot be safely displayed."
        case .tooLarge: return "The SVG exceeds the size limit."
        case .tooComplex: return "The SVG exceeds the complexity limit."
        }
    }
}

private enum SVGLimits {
    static let maxUTF8Bytes = 2_000_000
    static let maxNodeCount = 10_000
    static let maxDepth = 64
}

/// Extracts the first complete SVG element from a model response.
public enum SVGExtractor {
    public static func extract(from response: String) throws -> String {
        guard !response.isEmpty else { throw SVGError.emptyResponse }
        guard response.utf8.count <= SVGLimits.maxUTF8Bytes else { throw SVGError.tooLarge }

        let bytes = Array(response.utf8)
        guard let start = firstSVGStart(in: bytes) else { throw SVGError.svgNotFound }

        var depth = 0
        var cursor = start

        while cursor < bytes.count {
            guard bytes[cursor] == 0x3c else {
                cursor += 1
                continue
            }

            if hasPrefix(bytes, at: cursor, prefix: [0x3c, 0x21, 0x2d, 0x2d]) {
                guard let end = findSequence(bytes, sequence: [0x2d, 0x2d, 0x3e], after: cursor + 4) else {
                    throw SVGError.malformed
                }
                cursor = end + 3
                continue
            }

            if hasPrefix(bytes, at: cursor, prefix: [0x3c, 0x21, 0x5b, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5b]) {
                guard let end = findSequence(bytes, sequence: [0x5d, 0x5d, 0x3e], after: cursor + 9) else {
                    throw SVGError.malformed
                }
                cursor = end + 3
                continue
            }

            if hasPrefix(bytes, at: cursor, prefix: [0x3c, 0x3f]) {
                guard let end = findSequence(bytes, sequence: [0x3f, 0x3e], after: cursor + 2) else {
                    throw SVGError.malformed
                }
                cursor = end + 2
                continue
            }

            guard let end = findTagEnd(bytes, from: cursor + 1) else {
                throw SVGError.malformed
            }

            if isClosingSVG(in: bytes, at: cursor, tagEnd: end) {
                guard depth > 0 else { throw SVGError.malformed }
                depth -= 1
                if depth == 0 {
                    return String(decoding: bytes[start...end], as: UTF8.self)
                }
            } else if isOpeningSVG(in: bytes, at: cursor, tagEnd: end) {
                if !isSelfClosing(bytes, tagEnd: end) {
                    depth += 1
                } else if depth == 0 {
                    return String(decoding: bytes[start...end], as: UTF8.self)
                }
            }

            cursor = end + 1
        }

        // Once a first SVG start has been seen, do not skip it in search of a
        // later candidate. The validator must be allowed to record that first
        // shot as invalid.
        throw SVGError.malformed
    }

    private static func firstSVGStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = 0
        while index + 4 <= bytes.count {
            guard bytes[index] == 0x3c,
                  bytes[index + 1] == 0x73,
                  bytes[index + 2] == 0x76,
                  bytes[index + 3] == 0x67 else {
                index += 1
                continue
            }

            let afterName = index + 4
            if afterName == bytes.count || isTagNameBoundary(bytes[afterName]) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isOpeningSVG(in bytes: [UInt8], at index: Int, tagEnd: Int) -> Bool {
        guard index + 4 <= tagEnd,
              bytes[index] == 0x3c,
              bytes[index + 1] == 0x73,
              bytes[index + 2] == 0x76,
              bytes[index + 3] == 0x67 else { return false }
        return index + 4 == tagEnd || isTagNameBoundary(bytes[index + 4])
    }

    private static func isClosingSVG(in bytes: [UInt8], at index: Int, tagEnd: Int) -> Bool {
        guard index + 5 <= tagEnd,
              bytes[index] == 0x3c,
              bytes[index + 1] == 0x2f,
              bytes[index + 2] == 0x73,
              bytes[index + 3] == 0x76,
              bytes[index + 4] == 0x67 else { return false }
        return index + 5 == tagEnd || isTagNameBoundary(bytes[index + 5])
    }

    private static func isSelfClosing(_ bytes: [UInt8], tagEnd: Int) -> Bool {
        var index = tagEnd - 1
        while index >= 0, isXMLWhitespace(bytes[index]) {
            index -= 1
        }
        return index >= 0 && bytes[index] == 0x2f
    }

    private static func findTagEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var quote: UInt8?
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if byte == activeQuote { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x3e {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func findSequence(_ bytes: [UInt8], sequence: [UInt8], after start: Int) -> Int? {
        guard !sequence.isEmpty, start <= bytes.count - sequence.count else { return nil }
        var index = start
        while index <= bytes.count - sequence.count {
            if bytes[index..<(index + sequence.count)].elementsEqual(sequence) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func hasPrefix(_ bytes: [UInt8], at index: Int, prefix: [UInt8]) -> Bool {
        guard index <= bytes.count - prefix.count else { return false }
        return bytes[index..<(index + prefix.count)].elementsEqual(prefix)
    }

    private static func isTagNameBoundary(_ byte: UInt8) -> Bool {
        isXMLWhitespace(byte) || byte == 0x3e || byte == 0x2f
    }

    private static func isXMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }
}

/// Performs a strict, no-IO safety check on an extracted SVG document.
public enum SVGValidator {
    public static func validate(_ svg: String) throws {
        guard !svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVGError.emptyResponse
        }
        guard svg.utf8.count <= SVGLimits.maxUTF8Bytes else { throw SVGError.tooLarge }

        let lowered = svg.lowercased()
        if lowered.contains("<!doctype") || lowered.contains("<!entity") || lowered.contains("<?xml-stylesheet") {
            throw SVGError.unsafeContent
        }

        let delegate = SVGValidationDelegate()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()

        if let issue = delegate.issue { throw issue }
        guard delegate.didParse, delegate.rootSeen, delegate.rootClosed else { throw SVGError.malformed }
        guard delegate.hasMeaningfulContent else { throw SVGError.emptyResponse }
    }
}

private final class SVGValidationDelegate: NSObject, XMLParserDelegate {
    var issue: SVGError?
    var didParse = false
    var rootSeen = false
    var rootClosed = false
    var hasMeaningfulContent = false

    private var depth = 0
    private var nodeCount = 0
    private var stack: [String] = []
    private var styleDepth: Int?
    private var styleText = String()

    func parserDidStartDocument(_ parser: XMLParser) {
        depth = 0
        nodeCount = 0
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        didParse = issue == nil && rootSeen && rootClosed && depth == 0 && stack.isEmpty
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard issue == nil else { return }
        nodeCount += 1
        depth += 1

        guard nodeCount <= SVGLimits.maxNodeCount, depth <= SVGLimits.maxDepth else {
            reject(.tooComplex, parser: parser)
            return
        }

        let qualified = qName ?? elementName
        let local = localName(qualified)
        let lowerLocal = local.lowercased()

        if !rootSeen {
            guard depth == 1, qualified == "svg", local == "svg" else {
                reject(.malformed, parser: parser)
                return
            }
            rootSeen = true
        } else {
            guard !rootClosed else {
                reject(.malformed, parser: parser)
                return
            }
            if qualified.contains(":") && !qualified.hasPrefix("svg:") {
                reject(.unsafeContent, parser: parser)
                return
            }
        }

        switch lowerLocal {
        case "script", "foreignobject", "iframe", "object", "embed", "link",
             "set", "animate", "animatecolor", "animatetransform", "animatemotion", "mpath", "discard":
            reject(.unsafeContent, parser: parser)
            return
        default:
            break
        }

        validateAttributes(attributeDict, parser: parser)
        guard issue == nil else { return }

        if depth > 1 { hasMeaningfulContent = true }
        stack.append(local)

        if lowerLocal == "style" {
            styleDepth = depth
            styleText.removeAll(keepingCapacity: true)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard issue == nil else { return }
        let local = localName(qName ?? elementName)
        guard let expected = stack.popLast(), expected == local, depth > 0 else {
            reject(.malformed, parser: parser)
            return
        }

        if styleDepth == depth {
            do {
                try Self.validateCSS(styleText)
            } catch {
                reject(.unsafeContent, parser: parser)
                return
            }
            styleDepth = nil
            styleText.removeAll(keepingCapacity: true)
        }

        depth -= 1
        if depth == 0 { rootClosed = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard issue == nil else { return }
        if depth == 0 {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reject(.malformed, parser: parser)
            }
            return
        }
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasMeaningfulContent = true
        }
        if styleDepth != nil { styleText.append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard issue == nil else { return }
        let string = String(decoding: CDATABlock, as: UTF8.self)
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasMeaningfulContent = true
        }
        if styleDepth != nil { styleText.append(string) }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        reject(.unsafeContent, parser: parser)
    }

    func parser(_ parser: XMLParser, foundSkippedEntity name: String) {
        reject(.unsafeContent, parser: parser)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(.unsafeContent, parser: parser)
        return nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if issue == nil { issue = .malformed }
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        if issue == nil { issue = .malformed }
    }

    private func validateAttributes(_ attributes: [String: String], parser: XMLParser) {
        for (qualifiedName, value) in attributes {
            let lowerQualified = qualifiedName.lowercased()
            let local = localName(qualifiedName).lowercased()

            if lowerQualified == "xmlns" {
                if !value.isEmpty && value != "http://www.w3.org/2000/svg" {
                    reject(.unsafeContent, parser: parser)
                    return
                }
                // Namespace URIs are declarations, not CSS/resource values.
                continue
            } else if lowerQualified.hasPrefix("xmlns:") {
                let prefix = String(lowerQualified.dropFirst("xmlns:".count))
                let allowedNamespace: [String: String] = [
                    "xlink": "http://www.w3.org/1999/xlink",
                    "xml": "http://www.w3.org/XML/1998/namespace"
                ]
                guard allowedNamespace[prefix] == value else {
                    reject(.unsafeContent, parser: parser)
                    return
                }
                continue
            }

            if lowerQualified.contains(":") {
                let prefix = lowerQualified.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                if prefix != "xml" && prefix != "xmlns" && prefix != "xlink" && prefix != "svg" {
                    reject(.unsafeContent, parser: parser)
                    return
                }
            }

            if local.count > 2 && local.hasPrefix("on") {
                reject(.unsafeContent, parser: parser)
                return
            }

            if local == "href" || local == "src" || lowerQualified == "xml:base" {
                guard Self.isLocalFragment(value) else {
                    reject(.unsafeContent, parser: parser)
                    return
                }
            }

            let lowerValue = value.lowercased()
            let needsCSSValidation = local == "style"
                || Self.presentationAttributeNames.contains(local)
                || value.contains("\\")
                || lowerValue.contains("url")
                || lowerValue.contains("image-set")
                || lowerValue.contains("@")
                || lowerValue.contains("://")
                || lowerValue.contains("//")

            if needsCSSValidation {
                do {
                    try Self.validateCSS(value)
                } catch {
                    reject(.unsafeContent, parser: parser)
                    return
                }
            } else if value.lowercased().contains("url") {
                do {
                    try Self.validateCSS(value)
                } catch {
                    reject(.unsafeContent, parser: parser)
                    return
                }
            }
        }
    }

    private static func isLocalFragment(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#", trimmed.count > 1 else { return false }
        let fragment = trimmed.dropFirst()
        return !fragment.contains { character in
            character.isWhitespace || character == "/" || character == "\\" || character == "#" || character.isNewline
        }
    }

    private static let presentationAttributeNames: Set<String> = [
        "alignment-baseline", "baseline-shift", "clip", "clip-path", "clip-rule", "color",
        "color-interpolation", "color-interpolation-filters", "color-profile", "color-rendering",
        "cursor", "direction", "display", "dominant-baseline", "enable-background", "fill",
        "fill-opacity", "fill-rule", "filter", "flood-color", "flood-opacity", "font-family",
        "font-size", "font-size-adjust", "font-stretch", "font-style", "font-variant", "font-weight",
        "glyph-orientation-horizontal", "glyph-orientation-vertical", "image-rendering", "kerning",
        "letter-spacing", "lighting-color", "marker-end", "marker-mid", "marker-start", "mask",
        "opacity", "overflow", "paint-order", "pointer-events", "shape-rendering", "stop-color",
        "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap",
        "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "text-anchor",
        "text-decoration", "text-rendering", "unicode-bidi", "vector-effect", "visibility", "word-spacing",
        "writing-mode"
    ]

    private static func validateCSS(_ value: String) throws {
        let validationCopy = try cssValidationCopy(value)
        let lowered = validationCopy.lowercased()
        if lowered.contains("\\") || lowered.contains("@") || lowered.contains("expression(") || lowered.contains("javascript:") || lowered.contains("vbscript:") || lowered.contains("-moz-binding") || lowered.contains("behavior:") || lowered.contains("image-set") || lowered.contains("://") || lowered.contains("//") {
            throw SVGError.unsafeContent
        }

        var searchStart = lowered.startIndex
        while let range = lowered.range(of: "url", range: searchStart..<lowered.endIndex) {
            var cursor = range.upperBound
            while cursor < lowered.endIndex, lowered[cursor].isWhitespace {
                cursor = lowered.index(after: cursor)
            }
            guard cursor < lowered.endIndex, lowered[cursor] == "(" else {
                searchStart = range.upperBound
                continue
            }

            let open = cursor
            cursor = lowered.index(after: open)
            var quote: Character?
            var close: String.Index?
            while cursor < lowered.endIndex {
                let character = lowered[cursor]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "'" || character == "\"" {
                    quote = character
                } else if character == ")" {
                    close = cursor
                    break
                }
                cursor = lowered.index(after: cursor)
            }
            guard let close else { throw SVGError.unsafeContent }

            var argument = String(lowered[lowered.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            if argument.count >= 2,
               (argument.first == "'" && argument.last == "'") || (argument.first == "\"" && argument.last == "\"") {
                argument.removeFirst()
                argument.removeLast()
                argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard isLocalFragment(argument) else { throw SVGError.unsafeContent }
            searchStart = lowered.index(after: close)
        }
    }

    private static func cssValidationCopy(_ value: String) throws -> String {
        var copy = String()
        copy.reserveCapacity(value.count)

        var index = value.startIndex
        var quote: Character?
        while index < value.endIndex {
            let character = value[index]

            if let activeQuote = quote {
                copy.append(character)
                if character == activeQuote {
                    quote = nil
                }
                index = value.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                copy.append(character)
                index = value.index(after: index)
                continue
            }

            if character == "/" {
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == "*" {
                    index = value.index(after: next)
                    var closed = false
                    while index < value.endIndex {
                        if value[index] == "*" {
                            let after = value.index(after: index)
                            if after < value.endIndex, value[after] == "/" {
                                index = value.index(after: after)
                                closed = true
                                break
                            }
                        }
                        index = value.index(after: index)
                    }
                    guard closed else { throw SVGError.unsafeContent }
                    continue
                }
            } else if character == "*" {
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == "/" {
                    throw SVGError.unsafeContent
                }
            }

            copy.append(character)
            index = value.index(after: index)
        }

        guard quote == nil else { throw SVGError.unsafeContent }
        return copy
    }

    private func reject(_ error: SVGError, parser: XMLParser) {
        if issue == nil { issue = error }
        parser.abortParsing()
    }

    private func localName(_ qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }
}
