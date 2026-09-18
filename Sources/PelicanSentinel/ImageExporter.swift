import Foundation
import PelicanCore

enum ImageExporter {
    struct ExportedFiles: Equatable {
        let svg: URL
        let png: URL?
    }

    private enum ExportError: LocalizedError {
        case malformedRoot
        case unsupportedViewport
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .malformedRoot: return "The SVG root could not be annotated."
            case .unsupportedViewport: return "The SVG viewBox is not usable for annotation."
            case .invalidDimensions: return "The SVG dimensions are not usable for annotation."
            }
        }
    }

    private struct RootAttribute {
        let name: String
        let value: String
        let quote: Character
    }

    private struct SVGDocument {
        let prefix: String
        let openingTag: String
        let children: String
        let suffix: String
    }

    private struct Viewport {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct Dimension {
        let value: Double
        let unit: String

        var cssPixels: Double {
            switch unit {
            case "cm": return value * (96 / 2.54)
            case "mm": return value * (96 / 25.4)
            case "in": return value * 96
            case "pt": return value * (96 / 72)
            case "pc": return value * 16
            default: return value
            }
        }
    }

    private struct Footer {
        let height: Double
        let markup: String
    }

    static func footerText(for record: ResultRecord, timeZone: TimeZone = .current) -> String {
        let returnedModel = record.returnedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelLine: String
        if returnedModel.isEmpty {
            modelLine = "Requested model: \(record.requestedModel.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            modelLine = "Returned model: \(returnedModel)"
        }

        let completedAt = record.completedAt ?? record.startedAt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let seconds = timeZone.secondsFromGMT(for: completedAt)
        let sign = seconds >= 0 ? "+" : "-"
        let absoluteSeconds = Swift.abs(seconds)
        let offset = "UTC\(sign)\(String(format: "%02d", absoluteSeconds / 3600)):\(String(format: "%02d", (absoluteSeconds % 3600) / 60))"
        return "\(modelLine)\nCompleted: \(formatter.string(from: completedAt)) \(offset)"
    }

    static func annotatedSVG(svg: String, record: ResultRecord, timeZone: TimeZone = .current) throws -> String {
        try SVGValidator.validate(svg)

        let document = try document(from: svg)
        let attributes = try rootAttributes(from: document.openingTag)
        if let style = attributes.first(where: { $0.name.lowercased() == "style" })?.value,
           style.range(of: "(?:^|;)\\s*(?:(?:min|max)-)?(?:width|height)\\s*:", options: [.regularExpression, .caseInsensitive]) != nil {
            throw ExportError.invalidDimensions
        }
        let viewport = try originalViewport(attributes: attributes)
        let footer = makeFooter(text: footerText(for: record, timeZone: timeZone), viewport: viewport)
        let dimensions = try expandedDimensions(attributes: attributes, viewport: viewport, footerHeight: footer.height)

        let keptAttributes = attributes
            .filter { !["viewbox", "width", "height"].contains($0.name.lowercased()) }
            .map { " \($0.name)=\($0.quote)\($0.value)\($0.quote)" }
            .joined()
        let originalViewBox = viewBoxString(viewport)
        let expandedViewBox = "\(number(viewport.x)) \(number(viewport.y)) \(number(viewport.width)) \(number(viewport.height + footer.height))"
        let originalViewport = """
        <svg x="\(number(viewport.x))" y="\(number(viewport.y))" width="\(number(viewport.width))" height="\(number(viewport.height))" viewBox="\(originalViewBox)" preserveAspectRatio="none" overflow="hidden" style="overflow:hidden !important">\(document.children)</svg>
        """
        let output = """
        \(document.prefix)<svg\(keptAttributes) viewBox="\(expandedViewBox)" width="\(dimensionString(dimensions.width))" height="\(dimensionString(dimensions.height))">
        \(originalViewport)\(footer.markup)
        </svg>\(document.suffix)
        """
        try SVGValidator.validate(output)
        return output
    }

    static func export(svg: String, png: Data?, record: ResultRecord, directory: URL) throws -> ExportedFiles {
        let fileManager = FileManager.default
        let destination = directory.standardizedFileURL
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let staging = destination.appendingPathComponent(".pelican-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        let stagedSVG = staging.appendingPathComponent("pelican.svg")
        try Data(svg.utf8).write(to: stagedSVG, options: .withoutOverwriting)
        if let png {
            try png.write(to: staging.appendingPathComponent("pelican.png"), options: .withoutOverwriting)
        }

        var suffix = 1
        while true {
            let name = suffix == 1
                ? "PelicanSentinel-\(record.id.uuidString)"
                : "PelicanSentinel-\(record.id.uuidString)-\(suffix)"
            let exportDirectory = destination.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.moveItem(at: staging, to: exportDirectory)
                return ExportedFiles(
                    svg: exportDirectory.appendingPathComponent("pelican.svg"),
                    png: png == nil ? nil : exportDirectory.appendingPathComponent("pelican.png")
                )
            } catch {
                guard fileManager.fileExists(atPath: exportDirectory.path) else { throw error }
                suffix += 1
            }
        }
    }

    private static func document(from svg: String) throws -> SVGDocument {
        var cursor = svg.startIndex
        var rootStart: String.Index?
        var rootEnd: String.Index?

        while let tagStart = nextTagStart(in: svg, from: cursor) {
            if let afterSpecial = endOfSpecialConstruct(in: svg, at: tagStart) {
                cursor = afterSpecial
                continue
            }
            guard let tagEnd = tagEnd(in: svg, from: tagStart) else { throw ExportError.malformedRoot }
            if svgTag(in: svg, at: tagStart, endingAt: tagEnd) != nil {
                rootStart = tagStart
                rootEnd = tagEnd
                break
            }
            cursor = svg.index(after: tagEnd)
        }
        guard let rootStart, let rootEnd else { throw ExportError.malformedRoot }

        var depth = 1
        cursor = svg.index(after: rootEnd)
        while let tagStart = nextTagStart(in: svg, from: cursor) {
            if let afterSpecial = endOfSpecialConstruct(in: svg, at: tagStart) {
                cursor = afterSpecial
                continue
            }
            guard let tagEnd = tagEnd(in: svg, from: tagStart) else { throw ExportError.malformedRoot }
            if let tag = svgTag(in: svg, at: tagStart, endingAt: tagEnd) {
                switch tag {
                case .opening(let selfClosing):
                    if !selfClosing { depth += 1 }
                case .closing:
                    depth -= 1
                    if depth == 0 {
                        return SVGDocument(
                            prefix: String(svg[..<rootStart]),
                            openingTag: String(svg[rootStart...rootEnd]),
                            children: String(svg[svg.index(after: rootEnd)..<tagStart]),
                            suffix: String(svg[svg.index(after: tagEnd)...])
                        )
                    }
                }
            }
            cursor = svg.index(after: tagEnd)
        }
        throw ExportError.malformedRoot
    }

    private enum SVGTag {
        case opening(selfClosing: Bool)
        case closing
    }

    private static func nextTagStart(in string: String, from index: String.Index) -> String.Index? {
        string[index...].firstIndex(of: "<")
    }

    private static func endOfSpecialConstruct(in string: String, at start: String.Index) -> String.Index? {
        let suffix = string[start...]
        let terminator: String
        if suffix.hasPrefix("<!--") {
            terminator = "-->"
        } else if suffix.hasPrefix("<![CDATA[") {
            terminator = "]]>"
        } else if suffix.hasPrefix("<?") {
            terminator = "?>"
        } else {
            return nil
        }
        guard let range = string.range(of: terminator, range: start..<string.endIndex) else { return nil }
        return range.upperBound
    }

    private static func tagEnd(in string: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = string.index(after: start)
        while index < string.endIndex {
            let character = string[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = string.index(after: index)
        }
        return nil
    }

    private static func svgTag(in string: String, at start: String.Index, endingAt end: String.Index) -> SVGTag? {
        var index = string.index(after: start)
        var closing = false
        if index < end, string[index] == "/" {
            closing = true
            index = string.index(after: index)
        }
        let name = "svg"
        guard string.distance(from: index, to: end) >= name.count,
              string[index...].hasPrefix(name) else { return nil }
        let afterName = string.index(index, offsetBy: name.count)
        guard afterName == end || isXMLWhitespace(string[afterName]) || string[afterName] == "/" || string[afterName] == ">" else {
            return nil
        }
        if closing { return .closing }

        var last = string.index(before: end)
        while last > start, isXMLWhitespace(string[last]) {
            last = string.index(before: last)
        }
        return .opening(selfClosing: string[last] == "/")
    }

    private static func rootAttributes(from openingTag: String) throws -> [RootAttribute] {
        guard openingTag.hasPrefix("<svg") else { throw ExportError.malformedRoot }
        var attributes: [RootAttribute] = []
        var index = openingTag.index(openingTag.startIndex, offsetBy: 4)

        while index < openingTag.endIndex {
            while index < openingTag.endIndex, isXMLWhitespace(openingTag[index]) {
                index = openingTag.index(after: index)
            }
            guard index < openingTag.endIndex, openingTag[index] != ">", openingTag[index] != "/" else { break }

            let nameStart = index
            while index < openingTag.endIndex,
                  !isXMLWhitespace(openingTag[index]),
                  openingTag[index] != "=",
                  openingTag[index] != ">",
                  openingTag[index] != "/" {
                index = openingTag.index(after: index)
            }
            guard nameStart < index else { throw ExportError.malformedRoot }
            let name = String(openingTag[nameStart..<index])
            while index < openingTag.endIndex, isXMLWhitespace(openingTag[index]) {
                index = openingTag.index(after: index)
            }
            guard index < openingTag.endIndex, openingTag[index] == "=" else { throw ExportError.malformedRoot }
            index = openingTag.index(after: index)
            while index < openingTag.endIndex, isXMLWhitespace(openingTag[index]) {
                index = openingTag.index(after: index)
            }
            guard index < openingTag.endIndex, openingTag[index] == "\"" || openingTag[index] == "'" else {
                throw ExportError.malformedRoot
            }
            let quote = openingTag[index]
            index = openingTag.index(after: index)
            let valueStart = index
            while index < openingTag.endIndex, openingTag[index] != quote {
                index = openingTag.index(after: index)
            }
            guard index < openingTag.endIndex else { throw ExportError.malformedRoot }
            attributes.append(.init(name: name, value: String(openingTag[valueStart..<index]), quote: quote))
            index = openingTag.index(after: index)
        }
        return attributes
    }

    private static func originalViewport(attributes: [RootAttribute]) throws -> Viewport {
        if let value = attributes.first(where: { $0.name.lowercased() == "viewbox" })?.value {
            let parts = value.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "," }
            guard parts.count == 4,
                  let x = Double(String(parts[0])), let y = Double(String(parts[1])),
                  let width = Double(String(parts[2])), let height = Double(String(parts[3])),
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite,
                  width > 0, height > 0 else {
                throw ExportError.unsupportedViewport
            }
            return .init(x: x, y: y, width: width, height: height)
        }

        let width = try dimension(from: attributes.first(where: { $0.name.lowercased() == "width" })?.value)?.cssPixels ?? 300
        let height = try dimension(from: attributes.first(where: { $0.name.lowercased() == "height" })?.value)?.cssPixels ?? 150
        return .init(x: 0, y: 0, width: width, height: height)
    }

    private static func expandedDimensions(attributes: [RootAttribute], viewport: Viewport, footerHeight: Double) throws -> (width: Dimension, height: Dimension) {
        let width = try dimension(from: attributes.first(where: { $0.name.lowercased() == "width" })?.value) ?? .init(value: viewport.width, unit: "")
        let height = try dimension(from: attributes.first(where: { $0.name.lowercased() == "height" })?.value) ?? .init(value: viewport.height, unit: "")
        let expandedHeight = height.value * (viewport.height + footerHeight) / viewport.height
        guard expandedHeight.isFinite, expandedHeight > 0 else { throw ExportError.invalidDimensions }
        return (width, .init(value: expandedHeight, unit: height.unit))
    }

    private static func dimension(from rawValue: String?) throws -> Dimension? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard !value.isEmpty else { throw ExportError.invalidDimensions }

        let units = ["px", "cm", "mm", "in", "pt", "pc"]
        let lowercased = value.lowercased()
        let unit: String
        if let suffix = units.first(where: { lowercased.hasSuffix($0) }) {
            unit = suffix
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unit = ""
        }

        guard let number = Double(value), number.isFinite, number > 0 else { throw ExportError.invalidDimensions }
        let dimension = Dimension(value: number, unit: unit)
        guard dimension.cssPixels.isFinite, dimension.cssPixels > 0 else { throw ExportError.invalidDimensions }
        return dimension
    }

    private static func makeFooter(text: String, viewport: Viewport) -> Footer {
        let fontSize = max(3, min(viewport.height * 0.08, viewport.width / 50))
        let padding = max(2, fontSize * 0.75)
        let usableWidth = max(1, viewport.width - (padding * 2))
        let estimatedCharacters = usableWidth / max(1, fontSize * 0.62)
        let characterLimit = Int(min(2_048, max(8, floor(estimatedCharacters))))
        let lines = wrappedLines(text, characterLimit: characterLimit)
        let lineHeight = fontSize * 1.35
        let height = (padding * 2) + (Double(lines.count) * lineHeight)
        let footerY = viewport.y + viewport.height
        let textX = viewport.x + padding
        let strokeWidth = max(0.25, fontSize / 16)
        let textElements = lines.enumerated().map { index, line in
            let baseline = footerY + padding + fontSize + (Double(index) * lineHeight)
            return "<text x=\"\(number(textX))\" y=\"\(number(baseline))\" style=\"font-family:monospace !important; font-size:\(number(fontSize))px !important; font-weight:400 !important; text-anchor:start !important; stroke:none !important; fill:#111111 !important; display:inline !important; pointer-events:none !important\">\(xmlEscaped(line))</text>"
        }.joined(separator: "\n")
        let markup = """
        <g>
        <rect x="\(number(viewport.x))" y="\(number(footerY))" width="\(number(viewport.width))" height="\(number(height))" style="fill:#ffffff !important; stroke:#c7c7c7 !important; stroke-width:\(number(strokeWidth)) !important; display:inline !important"/>
        \(textElements)
        </g>
        """
        return .init(height: height, markup: markup)
    }

    private static func wrappedLines(_ text: String, characterLimit: Int) -> [String] {
        var result: [String] = []
        for logicalLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var characters = Array(logicalLine)
            if characters.isEmpty {
                result.append("")
                continue
            }
            while !characters.isEmpty {
                let upperBound = min(characterLimit, characters.count)
                var splitAt = upperBound
                if upperBound < characters.count,
                   let whitespace = characters[..<upperBound].lastIndex(where: { $0.isWhitespace }),
                   whitespace > 0 {
                    splitAt = whitespace + 1
                }
                let chunk = String(characters[..<splitAt]).trimmingCharacters(in: .whitespaces)
                result.append(chunk)
                characters.removeFirst(splitAt)
                while characters.first?.isWhitespace == true { characters.removeFirst() }
            }
        }
        return result
    }

    private static func viewBoxString(_ viewport: Viewport) -> String {
        "\(number(viewport.x)) \(number(viewport.y)) \(number(viewport.width)) \(number(viewport.height))"
    }

    private static func dimensionString(_ dimension: Dimension) -> String {
        "\(number(dimension.value))\(dimension.unit)"
    }

    private static func number(_ value: Double) -> String {
        var result = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }

    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func isXMLWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }
}
